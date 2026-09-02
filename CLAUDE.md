# ota — over-the-air releases for the fleet's Mac apps

The release flow that mux, disk and ccc each carried as a hand-copied shell
script, in one place: bundle (SwiftPM apps), sign inside-out with Developer
ID, notarize, staple, zip, single-item Sparkle appcast on the CDN, verify the
live feed — plus the app-side library every consumer imports instead of
copying (`Updater`, `BuildInfo`, `CLIInstall`). Seeded 2026-09-02 out of
`~/code/fun/lore`'s well after the three copies were diffed; the trail lives
in the lore wiki (`~/code/personal/lore-wiki/projects/ota.md`). Decision
narrative: `docs/DESIGN.md`.

## Thesis

**Everything after "here is a .app" is one script; everything before it is
a toolbox; the app side is a library.** The three consumers differ only in
app name, feed prefix, and which nested code carries entitlements — and that
last one is derivable from the bundle. The build step is per-app and stays in
each repo (mux is xcodegen + an FFmpeg prune, disk is universal + a widget,
ccc is one `swift build`); `ota` never owns the build. The credentials (the
Developer ID cert, the notarytool profile, the Sparkle EdDSA private key)
live in exactly one Keychain, so the CLI has exactly one install target and
"distribution" of the tool is a non-problem: install once, repos call it by
name.

## Locked decisions (2026-09-02; rationale in docs/DESIGN.md)

- **Swift.** The consumers are Swift repos, the app-side half is Swift, and
  the tool wants the same primitives (plist, version, bundle layout). One
  library, two faces, no second runtime. Bun was the house CLI default and
  was rejected for this on precedent alone not being a reason.
- **One repo, three products, one tag line.** `OTAKit` (release primitives,
  zero deps), `ota` (the CLI over it; target `OTACLI` because `Sources/ota`
  and `Sources/OTA` are one directory on a case-insensitive disk), `OTA`
  (app-side, depends on Sparkle). Apps depend on `OTA` only. SemVer tags,
  consumers pin `from:`; pre-1.0 rules.
- **Plans are values.** Every step is a `Command` before it is a side
  effect: `Signing.plan`, `Notarize.plan`, `Appcast.generatePlan` return
  arrays a test can read and `ota release --dry-run` prints. The exact
  `codesign` order is asserted in `Tests/`, not described in a comment.
- **No secrets, no per-app canon here.** Public repo. The EdDSA PUBLIC key is
  pinned in each app's bundle spec (it is what the app trusts); the notary
  profile name is a flag with a default; the team id is read off the
  Keychain at run time. Nothing in this repo needs to be private, and
  nothing app-specific (a bundle id, an icon) lives here.
- **Sharing mechanism is git URL + tag, no registry.** SwiftPM resolves a
  package by URL the way every consumer already resolves Sparkle;
  `Package.resolved` pins the revision per consumer. The CLI is installed by
  `scripts/install` into a bin dir on PATH, the way lore is.

## Hard constraints (each one was paid for; provenance in DESIGN.md)

- **Never ship an ad-hoc signature across machines.** Gatekeeper refuses
  it, and TCC and login-item identity churn per rebuild. `--ad-hoc` exists
  for packaging tests on the building Mac only.
- **The feed is single-item, and that is a correctness property.** Every
  item points at the same stable key, so only the newest can be truthful.
  `--maximum-versions 1` does not guarantee it: archive other zips, delete
  the appcast, regenerate from empty, assert one `<item>`, then check the
  live `length=` against the zip's `content-length`.
- **Facts come off the binary, never typed twice.** `LSMinimumSystemVersion`
  from `LC_BUILD_VERSION`; archs from `lipo`; linked frameworks from `otool
  -L`. A plist that states what the binary already knows will disagree with
  it (ccc v0.1.3, refused by Sparkle on the receiving Mac).
- **`ditto --sequesterRsrc`** on every zip. Without it Archive Utility writes
  `._*` files into Sparkle.framework's root and Gatekeeper rejects it, while
  every check on the building Mac passes.
- **The app-side updater is gated on `SUFeedURL`.** A bare SwiftPM binary
  with Sparkle started blocks the main thread on a modal alert; the only
  symptom in a socket-faced app was "the socket never answers". The dev lane
  has no feed, and "which lane is this" is read off the plist, never a flag.
- **Sign inside-out, and re-sign Sparkle.** Hardened runtime's library
  validation demands every dylib carry our team id. Nested XPC services and
  plug-ins keep their entitlements (`--preserve-metadata=entitlements`) or
  notarization rejects them.

## Consumers and the migration order

mux (`~/code/fun/tv`, xcodegen; its copy lacks disk's single-item and
EdDSA-mismatch guards), disk (`~/code/fun/disk`, SwiftPM, universal +
widget), ccc (`~/code/fun/ccc`, SwiftPM, arm64, CLI symlinked into the
bundle). scry (`~/code/fun/scry`) has the dev lane only and a Sparkle lane
waiting.

1. **ccc first** — its session is live and hand-wrote the latest copy; it
   can steer while the interface is soft.
2. **disk second** — exercises the widget appex and the universal products
   dir, which ccc dropped.
3. **mux last, and it is the exit criterion**: when mux can delete
   `scripts/package-mac.sh` and lose nothing (its FFmpeg prune stays as its
   own pre-step), the tool is ready. Then an issue per consumer repo
   (graduation protocol: work as issues) and a message to each live session.
   scry gets told its Sparkle lane exists.

Each consumer's `scripts/package` becomes: its build, `ota bundle` (SwiftPM
apps), `ota release`. Its RELEASES.md shrinks to what is app-specific; the
shared runbook is `docs/RELEASING.md` here (to be written from disk's).

## State of the scaffold (what the first session inherits)

Wired and tested (13 tests, swift-testing): the parsers (`minos`, linked
frameworks, archs, Developer ID identity), `Version.read`, `BundleSpec` →
Info.plist, `Signing.insideOut` over a real bundle layout, the notarize and
appcast plans, the stable-key rewrite, `Feed.check`. Verbs: `ota version`
(works), `ota verify --feed <prefix>` (works, live), `ota release <App.app>
--feed <prefix> --dry-run` (prints the exact plan; against `/Applications/
Disk.app` it reproduces `disk/scripts/package` step for step, widget
included), `ota bundle` (prints the spec; assembly not wired).

Not wired, in the order they earn themselves:

- `ota release` execution: run the plan through `SystemRunner`, assert one
  `<item>` after `generate_appcast`, apply the stable-key rewrite, then run
  the two `share` lines (agent-runnable: disk's zips have never tripped the
  classifier) and finish with the live-feed check. Sparkle tools fetch on
  first use. The EdDSA key-match guard (`generate_keys -p` vs the app's
  `SUPublicEDKey`) before signing — a mismatch means every shipped update
  is rejected on the receiving end.
- `ota bundle` assembly: `Contents/MacOS`, `Info.plist`, icon, embed
  `Sparkle.framework` from the products dir, `@executable_path/../Frameworks`
  rpath is the consumer's linker flag. Universal: products dir
  `.build/apple/Products/Release`, and an arch assertion on every Mach-O in
  the bundle (a widget built by xcodebuild can be thin while the app is fat).
- `Feed.enclosure` reads `sparkle:version` off the enclosure tag; Sparkle 2
  feeds put it in a `<sparkle:version>` element — read both.
- `scripts/install` stamps the version into the bin (today `SelfID` reads
  `VERSION` through `#filePath`, which is the source tree).
- Release notes: no consumer feeds the appcast any; the GitHub Release
  already has generated notes. Cheap win, after the flow works.
- Launch at login (`SMAppService`) and the first-launch "install the
  command" offer in `OTA` — when ccc writes them, they move here.

First move for the first session: read this file, `docs/DESIGN.md`,
`disk/scripts/package` and `disk/RELEASES.md`; then wire `ota release`
execution against a `--ad-hoc` cut of ccc or disk before touching
notarization. Propose the consumer-side diff for ccc before writing it.

## Code conventions

- swift-testing (`import Testing`), one suite per module concern; tests
  build a fake `.app` under the temp dir rather than mocking `FileManager`.
- Every `ota` invocation self-identifies on stderr (`ota 0.0.1`) so a
  transcript says which build did the work. JSON output is a flag to add,
  not a second code path.
- Prompts that drive the CLI pin the invocation (`ota` on PATH — never
  `swift run` "from the current directory").
- No `sh -c` in plans when an argv will do; `find … -exec … ;` is passed as
  arguments, so the plan is printable and runnable without a shell.

## Fan-out rules (violations are findings, not workarounds)

- Ad-hoc spawns of generic agent types MUST pass an explicit model; omission
  inherits the main loop's model. Defined agents pin theirs in frontmatter.
- VERIFY the served model from the spawn's JSONL, never from the spawn
  parameter or completion notification. `lore spawns` mechanizes this
  post-hoc and flags requested-vs-served drift.
- Ledger every fan-out in the lore wiki log: per agent — scope, tokens,
  tools, duration, verified model.

## References

- `docs/DESIGN.md` — the diff of the three scripts, the seam, language and
  sharing-mechanism decisions, rejected alternatives, pitfalls with provenance.
- `~/code/fun/disk/scripts/package` + `RELEASES.md` — the reference
  implementation this scaffold was derived from; `~/code/fun/tv/RELEASES.md`
  the origin.
- Ghostty's custom Sparkle driver (`ccc/vendor/ghostty/macos/Sources/
  Features/Update/`, ~1600 lines) — the reference if a fleet-owned update UI
  is ever earned. Not before.
- The user operates suggest-first — challenge premises, propose alternatives.
