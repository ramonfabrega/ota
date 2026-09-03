# ota

Over-the-air releases for a small fleet of Mac apps: assemble the bundle
(SwiftPM apps), sign inside-out with Developer ID, notarize, staple, zip, cut
a single-item Sparkle appcast on a CDN, verify the live feed. Plus the
app-side halves: `OTA` (build info and a CLI-into-the-bundle installer, no
dependencies) and `OTAUpdater` (a Sparkle updater gated on the bundle).

Extracted from three hand-copied release scripts on 2026-09-02. Personal
tooling, public because nothing in it is secret. `CLAUDE.md` is the canon;
`docs/DESIGN.md` the narrative.

```sh
swift test
swift build -c release && scripts/install      # → ota on PATH
ota release .build/dist/App.app --feed app --dry-run
ota verify --feed app
```

Apps:

```swift
.package(url: "https://github.com/ramonfabrega/ota", from: "0.1.0"),
// the library half, zero deps — safe in a CLI-side target:
//   .product(name: "OTA", package: "ota")
// the updater, only in the executable target that embeds Sparkle.framework
// and carries -rpath @executable_path/../Frameworks:
//   .product(name: "OTAUpdater", package: "ota")
```

## What ota assumes

Everything `ota` takes for granted about the world outside this repo, in one
place. Not a configuration surface — none of it is a flag, most of it cannot
be, and `ota` is not portable to another fleet. It is an **inventory**: the
list is longer than it feels, and without it the answer to "what does this
need in order to run" is a careful read of the whole source.

Each line says what the value is and why it is that value. How to *obtain*
any of it is deliberately not here.

### Infrastructure it does not own

| Assumption | Where | Why |
| --- | --- | --- |
| `https://cdn.ramonfabrega.com/` | `Appcast.cdnBaseURL` | The fleet's CDN. Every feed URL, enclosure and stable key is `<base>/<feed>/…`, built through `Appcast.prefixURL(feed:)` so the app's `SUFeedURL`, the generated appcast and `ota verify` cannot disagree about where the feed lives. |
| `share` on PATH | `Appcast.publishPlan` | The personal upload command for that CDN — the same fact as the line above, which is why the two live adjacent. Invoked with `--permanent` to exempt both keys from the CDN's 30-day sweep (mux's artifacts were eaten by it once). Not checked before the release starts, so a Mac without it fails *after* notarization. |
| `<prefix>/<App>-latest.zip` + `<prefix>/appcast.xml` | `Appcast.stableKey` | Two keys per app, overwritten every release, so the CDN namespace never grows. The zip is published first: that ordering makes the mid-publish window "the key holds new bytes, the feed still describes the old ones", which no installed copy acts on. |
| `~/Library/Application Support/<feed>-releases` | `ota release --feed-dir` | The local signing archive `generate_appcast` reads. Versioned zips accumulate here and on GitHub Releases; the CDN keeps only the latest. |

### Credentials, all in one login Keychain

| Assumption | Where | Why |
| --- | --- | --- |
| A `Developer ID Application:` identity | `Signing.developerID` | Read off `security find-identity` at run time rather than configured, so the team id is never typed. The first match wins; the fleet has one. Absent → `ota release` says so and offers `--ad-hoc`. |
| The Sparkle EdDSA **private** key | `generate_keys -p` | Signs every update. Its public half is pinned per app in the bundle (`--public-key`), and `ota release` compares the two *before the first signature* — a mismatch means every update this cut signs would be rejected on the receiving Mac. |
| `mux-notary`, a notarytool keychain profile | `ota release --profile` | The default. Notary profiles are per **Apple account**, not per app, so one serves the fleet; the name is a leftover from the first app to need one. |

There is exactly one install target — the Mac holding all three — which is
why "distributing the tool" is a non-problem.

### Pinned externals

| Assumption | Where | Why |
| --- | --- | --- |
| Sparkle tools `2.9.4` | `Appcast.sparkleToolsVersion` | `generate_appcast` and `generate_keys`, fetched from that tag's GitHub release tarball on first use and cached at `~/Library/Caches/ota-sparkle-tools/<version>/bin`. Fetched as four argv commands, never `sh -c`, so the plan prints and runs without a shell. |
| `Sparkle.framework/Versions/B` | `Signing.insideOut` | Sparkle 2's current version directory, hardcoded. One symlink read from being version-proof; correct for 2.9. |
| `--maximum-versions 1 --maximum-deltas 0` | `Appcast.generatePlan` | Necessary and **not sufficient**: the feed is regenerated from an emptied directory and then asserted single-item, because `generate_appcast` keeps an older entry across an arch transition regardless of this flag. |
| ~13 tools on PATH | throughout | `codesign`, `ditto`, `otool`, `lipo`, `spctl`, `security`, `git`, `curl`, `tar`, `find`, plus `xcrun notarytool` / `stapler`. Xcode command line tools and base macOS; none is version-pinned. |

### Conventions it imposes on a consumer

| Assumption | Where | Why |
| --- | --- | --- |
| `VERSION` at the repo root, `MAJOR.MINOR.PATCH` | `Version.read` | One place to bump the marketing version. |
| `git rev-list --count HEAD` is the build number | `Version.read` | Monotonic with zero upkeep, and it is what Sparkle compares — so a dev build (commits past the tag) always outranks the released zip and is never offered a downgrade. |
| `.build/release`, or `.build/apple/Products/Release` with `--universal` | `Bundler.productsDirectory` | SwiftPM's multi-arch build emits LIPO'd products elsewhere while `.build/release` stays a symlink to the host-arch build, so reading the wrong one ships a thin "universal" release silently. `--universal` proves every Mach-O is fat rather than assuming it. |
| `~/.local/bin` | `scripts/install` | Where `claude`'s own installer puts things, so it is on PATH on any Mac that runs the harness. `CLIInstall` prefers `/opt/homebrew/bin` and `/usr/local/bin` first and falls back to it. |
| macOS 14+ | `Package.swift` | The package floor. A *bundle's* `LSMinimumSystemVersion` is unrelated — that is read off the binary's `LC_BUILD_VERSION`, never typed. |

**Facts that are deliberately not assumptions**: the deployment target, the
architectures, and the frameworks to embed are all read off the built binary
(`otool`, `lipo`) rather than configured. A plist that states what the binary
already knows will eventually disagree with it — ccc v0.1.3 shipped one and
Sparkle refused the update on the receiving Mac.

Nothing app-specific lives here: bundle ids, icons, display names and the
EdDSA public key are flags each consumer's `scripts/package` passes.
