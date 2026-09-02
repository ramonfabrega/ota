# ota — design narrative

## Origin (2026-09-02)

mux built the flow on 2026-07-09 (`tv/scripts/package-mac.sh`): Developer ID
+ hardened runtime, notarytool, staple, `ditto --sequesterRsrc`, Sparkle
appcast on the personal CDN with two overwritten stable keys. disk ported it
wholesale on 07-17 and fixed two things on 07-18 (the single-item feed
guarantee after v0.6.0 published a two-item feed pointing at one zip; an
EdDSA key-mismatch guard). mux's copy never received either fix. ccc copied
disk's on 09-02, dropped the universal build, and shipped four cuts in a day,
finding two more things (the SUFeedURL gate; minos from the binary). The lore
wiki had flagged "third consumer" as the extraction threshold on 07-17; ccc
was it.

## The diff (three package scripts, two make-bundles, app names normalized)

**After the .app: one script.** Developer ID lookup, the sign array, the
Sparkle inside-out list, `codesign --verify`, `ditto --sequesterRsrc`,
notarytool + staple + spctl + re-zip, the Sparkle tools fetch, appcast
generation, the stable-key sed, the two `share` lines — identical in all
three. Per-app tokens: app name; feed prefix (always the name lowercased);
which nested code is signed before the app with which entitlements (disk:
the widget appex; mux: every embedded framework plus `--entitlements` on the
app; ccc: nothing). A generic inside-out walk over
`Contents/{Frameworks,PlugIns,XPCServices}` with
`--preserve-metadata=entitlements` covers all three without a manifest
field — verified by `ota release --dry-run /Applications/Disk.app`
reproducing disk's script step for step.

**Before the .app: nothing alike, but one toolbox.** mux: vendor.sh,
xcodebuild, an otool framework prune, an FFmpeg static check. disk: universal
`swift build`, an xcodebuild widget. ccc: one `swift build`. Yet the
primitives inside repeat — version (VERSION + commit count), products dir
(host vs universal), minos, linked frameworks (mux prunes with it, ccc
asserts with it: what the binary links must be embedded, nothing else need
be), arch check, plist assembly. That is the deep-module shape: six verbs,
two or three arguments each, every copied comment block hidden inside.

**The app side had diverged by UI framework and grown.** disk's updater is
SwiftUI `Commands` with no gate; ccc's is AppKit with the gate, plus
`CLIInstall` and `BuildInfo` (191 lines) for the symlink-into-bundle install
with a first-launch offer. scry has the same symlink in its install script
and no Swift for it. Non-trivial now, and about to grow (launch at login).

## The seam

`ota` owns everything downstream of a built `.app`, and a toolbox upstream
of it for SwiftPM apps. It never owns the build, because the build is the
only part that is genuinely per-app and because mux is not SwiftPM. The
consumer's `scripts/package` is: build, `ota bundle` (SwiftPM), `ota
release`. The test of the seam is mux: if it cannot delete its script and
keep only its FFmpeg pre-step, the seam is wrong.

## Language: Swift, not Bun

Bun was the default on precedent (`share`, `lore`, incur conventions). The
job is orchestrating `codesign`, `notarytool`, `ditto` and
`generate_appcast` — any language is a wrapper around exec. What decided
it: the consumers are Swift repos, the app-side half is Swift, and the tool
wants the same primitives (plist read/write via `PropertyListSerialization`,
version from a bundle, bundle layout). One library, two faces, no second
runtime, and the release tool for a fleet of Swift apps does not read as
foreign the day someone opens it cold. Rust and Go would add a toolchain for
a subprocess orchestrator. The discipline from the Bun lane is kept:
self-identifying invocations, plans printable as commands, tests that pin
the format of every tool's output.

## Sharing mechanism: git URL + tag, one install

SwiftPM has no registry step; a package is a repo with `Package.swift` and
consumers resolve it by URL + SemVer tag, exactly how every consumer already
pulls Sparkle. `Package.resolved` pins the revision per consumer, so a bad
tag reaches no app until that app bumps. Apple's package registry protocol
exists and nobody runs one for private code; the repo is public anyway (no
secrets: the EdDSA public key is the app's to pin, the team id is a Keychain
lookup, the profile name is a flag).

The CLI has one install target because the credentials live in one
Keychain (the Studio's): `scripts/install` builds release and copies the
binary to a bin dir on PATH, the way lore is installed. No Homebrew tap, no
Mint.

## One repo, three products

`OTAKit` (release primitives, zero deps), `ota` (the CLI), `OTA` (app-side,
depends on Sparkle). Apps depend on `OTA` only, so the CLI's code never
enters an app build; the CLI build does resolve Sparkle (SwiftPM resolves
the package graph whole) — a binary xcframework download, acceptable. One
tag versions all three. The executable target is `OTACLI` because
`Sources/ota` and `Sources/OTA` are the same directory on APFS's default
case-insensitive volumes — found at first build.

## Plans are values

`Command` is a struct; `Signing.plan`, `Notarize.plan`,
`Appcast.generatePlan`, `Appcast.publishPlan` return `[Command]`; a `Runner`
executes. Tests read the plan (the exact `codesign` order, the
`--preserve-metadata=entitlements` on the right steps, the re-zip after
staple) instead of the flow being described in comments per repo. `--dry-run`
prints it. No `sh -c` when an argv will do.

## The update UI

All three consumers use Sparkle's standard user driver with no delegate: the
"update available" window, the download bar and the relaunch prompt are
Sparkle's. A flash on mux is most likely size — a ~6 MB zip on a fast CDN
finishes download and extract within a frame. Ghostty replaced the driver
with its own pill + popover + view model (~1600 lines, in ccc's vendor tree)
— the reference if a fleet-owned UI is ever earned by an app where the
standard dialog is wrong (ccc, menubar-resident and launched at login, is the
first plausible one). Two cheaper wins first: release notes in the appcast
(none of the apps feed any; the GitHub Release has generated notes), and the
gate.

## Pitfalls carried in, with provenance

- Single-item feed is correctness, not tidiness (disk v0.6.0, 752ddc82).
- `--sequesterRsrc` (mux v0.2.0 rejected on the Air, 2026-07-09).
- Inside-out signing; Downloader XPC keeps its sandbox; the widget appex
  keeps app-sandbox or notarization/chronod reject it (disk, mux).
- minos from `LC_BUILD_VERSION` (ccc v0.1.3 → v0.1.4).
- The SUFeedURL gate (ccc, found by `sample`, 2026-09-02).
- Universal: SwiftPM multi-arch emits to `.build/apple/Products/Release`;
  a widget built by xcodebuild is active-arch-only unless told (disk
  aa37f356).
- Hand-rolled `codesign` does not inject `com.apple.application-identifier`
  — matters only for CloudKit (mux 4b8fa39f). Out of scope, recorded.
- CDN keys must be `--permanent` or the 30-day sweep eats them (mux, dotfiles
  cdn README).
- Cut from master after merging, then rebuild the dev app: the released
  commit count can outrank the running dev build (disk v0.1.0, v0.5.0).
- Notary profiles are per Apple account (`mux-notary` serves the fleet).

## Rejected

- **SwiftPM command plugin** (`swift package release`): sandboxed (network
  needs a flag), and mux is not SwiftPM. Wrong layer.
- **A zsh script in a shared repo**: the cheapest dedup, but the bugs above
  are exactly what tests pin, and zsh grows unreadable at this size.
- **Bun / Rust / Go**: above.
- **Wrapping the Swift half first** ("Upkeep", mux's filing): the wrong half
  — 33 lines then; the shell flow had the drift.
- **A per-app manifest file**: the five per-app facts are CLI flags and a
  bundle-derived walk; a manifest would be a second place for them.
