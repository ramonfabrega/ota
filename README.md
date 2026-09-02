# ota

Over-the-air releases for a small fleet of Mac apps: assemble the bundle
(SwiftPM apps), sign inside-out with Developer ID, notarize, staple, zip, cut
a single-item Sparkle appcast on a CDN, verify the live feed. Plus the
app-side library (`OTA`): a Sparkle updater gated on the bundle, build info,
and a CLI-into-the-bundle installer.

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
.package(url: "https://github.com/ramonfabrega/ota", from: "0.0.1"),
// target dependency: .product(name: "OTA", package: "ota")
```
