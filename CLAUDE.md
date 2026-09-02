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
- **One repo, four products, one tag line.** `OTAKit` (release primitives,
  zero deps), `ota` (the CLI over it; target `OTACLI` because `Sources/ota`
  and `Sources/OTA` are one directory on a case-insensitive disk), `OTA`
  (app-side identity: `BuildInfo`, `CLIInstall` — ZERO DEPS), and
  `OTAUpdater` (the SUFeedURL-gated Sparkle updater). Apps depend on `OTA`,
  plus `OTAUpdater` if they self-update. The split was ccc's call and it is
  load-bearing: a consumer's CLI-side library (ccc's `CCCKit`) is what every
  test links, and a signed binary framework has no business behind two
  structs that never touch it. Only the executable target that embeds
  `Sparkle.framework` and carries the `@executable_path/../Frameworks` rpath
  takes `OTAUpdater`. SemVer tags, consumers pin `from:`; pre-1.0 rules.
- **Plans are values, and the guards are IN the plan.** A release is
  `[Step]`, not `[Command]`: three of its steps are not processes (the EdDSA
  key-match guard, the single-item assertion, the stable-key rewrite) and one
  is conditional (fetch Sparkle's tools only when missing). A plan of
  commands could only ever print the parts that are not the guards — and the
  guards are the whole reason disk's copy of the script was better than
  mux's. `Command` stays the leaf, `Signing.plan` / `Notarize.plan` /
  `Appcast.generatePlan` build the steps, and `--dry-run` prints the guards
  where they fire. The exact `codesign` order is asserted in `Tests/`, not
  described in a comment.
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
  `--maximum-versions 1` does not guarantee it: archive other zips (every
  `*.zip`, not `<App>-v*.zip` — `generate_appcast` scans the DIRECTORY, not a
  name pattern), delete the appcast, regenerate from empty, assert one
  `<item>`, then check the live `length=` against the zip's `content-length`.
  The trigger is narrower than "sometimes", and was reproduced deliberately:
  `generate_appcast` prunes a same-arch predecessor itself, and keeps an
  older item only when the newer one's HARDWARE REQUIREMENTS do not cover
  it — an arch transition, in either direction. Every consumer's first
  universal cut is the exposed one.
- **A release's input is a build product, never an installed app.** Signing
  is in place and the zip lands beside the bundle, so `ota release
  /Applications/X.app` re-signs the copy you are running and publishes it —
  and the EdDSA guard passes, because it is the real key. `/Applications/
  Disk.app` is the documented `--dry-run` demo, i.e. the most likely path to
  be typed one day without the flag, so the path is refused outright. The
  general form, for any fleet CLI: a documented demo one flag away from an
  irreversible action will eventually be run without the flag.
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

1. ~~**ccc first**~~ — **DONE, v0.1.8 (2026-09-02)**, and it steered the
   interface while it was soft: the `OTA`/`OTAUpdater` split and naming the
   peer at the decode are both ccc's calls. Its old lane is retired.
2. **disk second** — exercises the widget appex and the universal products
   dir, which ccc dropped. It is also the first consumer that CAN hit the
   arch-transition feed bug, being the only fat one.
3. **mux last, and it is the exit criterion**: when mux can delete
   `scripts/package-mac.sh` and lose nothing (its FFmpeg prune stays as its
   own pre-step), the tool is ready. Then an issue per consumer repo
   (graduation protocol: work as issues) and a message to each live session.
   scry gets told its Sparkle lane exists.

Each consumer's `scripts/package` becomes: its build, `ota bundle` (SwiftPM
apps), `ota release`. Its RELEASES.md shrinks to what is app-specific; the
shared runbook is `docs/RELEASING.md` here (to be written from disk's).

## State (v0.1.0, 2026-09-02 — the flow is proven end to end)

**ccc v0.1.8 shipped through `ota release` with no flags**: inside-out
signing, notarized on the first submission, stapled, single-item appcast on
the fleet's key, both CDN keys, live-feed check green — and air installed it
through Sparkle from that feed. ccc's `scripts/package` is now its build plus
`ota bundle` and `ota release`; `scripts/make-bundle`, `Updater.swift` and
the `BuildInfo`/`CLIInstall` halves of its `Hosts/BuildInfo.swift` are gone
(ccc `docs/DESIGN.md` §6a). Its old lane is retired. That is the seam
holding for one consumer, which is what disk and mux were waiting on.

Wired and tested (42 tests, swift-testing): the parsers (`minos`, linked
frameworks, archs, Developer ID identity), `Version.read`, `BundleSpec` →
Info.plist, `Signing.insideOut` over a real bundle layout, the whole release
plan as `[Step]` with its guards in position, the executor and each guard's
failure message, `Bundler` assembly and the arch assertion, `Feed.check`,
and the runner's concurrent pipe drain (a child that writes 200K to the pipe
nobody reads is what the old one deadlocked on).

Verbs, all live: `ota version`; `ota bundle` (assembles for real — executable,
whatever the binary links, icon, an already-built `.appex` stamped to the
app's version, `Info.plist`; `--universal` reads `.build/apple/Products/
Release` and asserts every Mach-O is fat); `ota release` (executes, and
`--dry-run` prints the plan INCLUDING the guards; refuses a path under
`/Applications` or `~/Applications`, because signing is in place and the zip
lands beside the bundle, so the documented demo was one flag from a live
release); `ota verify --feed <prefix>` (live) and `--appcast <path>` (the
same single-item guard on a local feed).

Not wired, in the order they earn themselves:

- disk second (the widget appex and the universal products dir, which ccc
  dropped), then mux, which is the exit criterion: when mux can delete
  `scripts/package-mac.sh` and lose nothing, the tool is done.
- Release notes: no consumer feeds the appcast any; the GitHub Release
  already has generated notes.
- `docs/RELEASING.md`, the shared runbook. Better written from a real cut
  than ahead of one — there is now a real cut to write it from.
- Launch at login (`SMAppService`) and the first-launch "install the
  command" offer in `OTA` — when ccc writes them, they move here.

Recorded, not fixed: `Signing.insideOut` hardcodes Sparkle's `Versions/B`
(fine for 2.9, one symlink read from being version-proof), and it does not
recurse into a non-Sparkle framework's own nested code (fine for all three
consumers today).

## Code conventions

- swift-testing (`import Testing`), one suite per module concern; tests
  build a fake `.app` under the temp dir rather than mocking `FileManager`.
- Every `ota` invocation self-identifies on stderr (`ota 0.1.0`) so a
  transcript says which build did the work. The version is the compiled-in
  `otaVersion`, not a read of `VERSION` — an installed binary is a copy and
  cannot find the repo — and one test holds the two together. JSON output is
  a flag to add, not a second code path.
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
