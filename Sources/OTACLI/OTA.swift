import ArgumentParser
import Foundation
import OTAKit

/// The fleet's release flow as a command. Installed once, on the Mac that
/// holds the Developer ID cert, the notarytool profile and the Sparkle EdDSA
/// key; every app repo's `scripts/package` is its build step plus one call.
@main
struct OTA: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ota",
        abstract: "Over-the-air releases for the fleet's Mac apps: bundle, sign, notarize, staple, appcast, verify.",
        version: SelfID.line,
        subcommands: [Version.self, Bundle.self, Release.self, Verify.self]
    )
}

/// Every invocation self-identifies on stderr (lore's convention) so a
/// transcript says which build did the work.
enum SelfID {
    static let line = "ota \(otaVersion)"
    static func announce() {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The VERSION + commit-count version of a repo.")

    @Option(help: "Repo root (default: cwd).") var repo: String = FileManager.default.currentDirectoryPath

    func run() throws {
        SelfID.announce()
        let v = try OTAKit.Version.read(repo: URL(filePath: repo))
        print(v)
    }
}

struct Bundle: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Assemble <name>.app from a release build (SwiftPM's, or any executable).",
        discussion: """
        The toolbox upstream of a built bundle. It never builds: point it at \
        a products directory (or name the executable) and it places the \
        executable, any helpers, whatever the binaries link, the icon and any \
        already-built app extensions, then writes the Info.plist.

        Which LANE the bundle is, is the presence or absence of --feed: no \
        feed means no SUFeedURL, and the app-side updater never constructs \
        Sparkle at all. That absence is the one definition of "dev build" — \
        never a flag read at runtime. A --feed bundle must contain \
        Sparkle.framework: linked (and so embedded from the products dir), \
        or placed by --sparkle for an app that loads it at run time.
        """)

    @Option(help: "The .app's name, and the executable name inside it.") var name: String
    @Option(name: .customLong("bundle-id")) var bundleID: String
    @Option(name: .customLong("display-name")) var displayName: String?
    @Option(help: "Built product name, when it differs from --name (disk: DiskApp → Disk).") var product: String?
    @Option(help: "The built executable itself, instead of <products dir>/<product> (e.g. a cargo target/release/<bin>). What it links is looked up beside it.") var executable: String?
    @Option(name: .customLong("helper"), parsing: .upToNextOption, help: "A second built executable, placed in Contents/Helpers (repeatable). `ota release` signs it before the app.") var helpers: [String] = []
    @Flag(help: "Embed Sparkle.framework (ota's pinned \(Appcast.sparkleToolsVersion), fetched with the tools when missing) for an app that loads it at run time rather than linking it.") var sparkle = false
    @Option(help: "CDN prefix for self-update (e.g. ccc). Omit for the dev lane: no SUFeedURL, no Sparkle at runtime.") var feed: String?
    @Option(name: .customLong("public-key"), help: "Sparkle EdDSA public key (required with --feed).") var publicKey: String?
    @Option(help: "Icon file, copied into Contents/Resources (e.g. Design/AppIcon.icns).") var icon: String?
    @Option(name: .customLong("plugin"), parsing: .upToNextOption, help: "Already-built .appex to place in Contents/PlugIns (repeatable).") var plugins: [String] = []
    @Option(name: .customLong("extra"), parsing: .upToNextOption, help: "Extra Info.plist keys, KEY=VALUE (e.g. LSUIElement=1).") var extras: [String] = []
    @Option(help: "Where to write the bundle (default: <repo>/.build/<name>.app).") var out: String?
    @Flag(help: "Built with --arch arm64 --arch x86_64: read the LIPO'd products dir and assert every Mach-O is fat.") var universal = false
    @Option(help: "Repo root (default: cwd).") var repo: String = FileManager.default.currentDirectoryPath
    @Flag(name: .customLong("dry-run"), help: "Print the Info.plist and what would be placed; write nothing.") var dryRun = false

    func run() throws {
        SelfID.announce()
        let repoURL = URL(filePath: repo)
        let version = try OTAKit.Version.read(repo: repoURL)
        if executable != nil, product != nil {
            throw ValidationError("--executable names the binary outright; --product names it inside the products dir — pass one")
        }
        let executableURL: URL
        let products: URL
        if let executable {
            executableURL = URL(filePath: executable)
            products = executableURL.deletingLastPathComponent()
        } else {
            products = Bundler.productsDirectory(repo: repoURL, universal: universal)
            executableURL = products.appending(path: product ?? name)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ValidationError("no executable at \(executableURL.path) — build first"
                                  + (universal && executable == nil ? " (--universal reads the LIPO'd products dir; did the build pass --arch twice?)" : ""))
        }
        let helperURLs = helpers.map { URL(filePath: $0) }
        for helper in helperURLs where !FileManager.default.isExecutableFile(atPath: helper.path) {
            throw ValidationError("no helper at \(helper.path) — build it first")
        }
        // Never typed twice: the deployment target is whatever the binaries
        // were BUILT for. A plist that states it independently will disagree,
        // and Sparkle on the receiving Mac believes the plist (ccc v0.1.3).
        // With helpers there is one plist and several binaries: the highest.
        let minimums = try ([executableURL] + helperURLs).map { ($0, try Binary.minos(of: $0)) }
        let minos = Binary.highest(minimums.map(\.1))!
        let raisedBy = minimums.dropFirst().first { $0.1 == minos && minimums[0].1 != minos }?.0

        var feedSpec: BundleSpec.Feed?
        if let feed {
            guard let publicKey else { throw ValidationError("--feed needs --public-key") }
            feedSpec = .init(url: Appcast.prefixURL(feed: feed) + "appcast.xml", publicEDKey: publicKey)
        } else if publicKey != nil {
            throw ValidationError("--public-key without --feed: a bundle with a key and no feed still never updates")
        }

        var extra: [String: String] = [:]
        for pair in extras {
            guard let split = pair.firstIndex(of: "=") else { throw ValidationError("--extra wants KEY=VALUE, got \(pair)") }
            extra[String(pair[..<split])] = String(pair[pair.index(after: split)...])
        }
        let iconURL = icon.map { URL(filePath: $0) }
        let spec = BundleSpec(name: name, displayName: displayName, bundleID: bundleID, version: version,
                              minimumSystemVersion: minos, feed: feedSpec,
                              iconFile: iconURL?.deletingPathExtension().lastPathComponent, extra: extra)
        let outURL = out.map { URL(filePath: $0) } ?? repoURL.appending(path: ".build/\(name).app")
        let toolsBin = Appcast.toolsBin()
        let sparkleFramework = Appcast.framework(toolsBin: toolsBin)
        let input = Bundler.Input(spec: spec, executable: executableURL, productsDirectory: products,
                                  icon: iconURL, plugins: plugins.map { URL(filePath: $0) },
                                  helpers: helperURLs, frameworks: sparkle ? [sparkleFramework] : [])

        guard !dryRun else {
            print(String(decoding: try spec.infoPlistXML(), as: UTF8.self))
            print("would write \(outURL.path)", to: &standardError)
            print("  executable: \(executableURL.path) → Contents/MacOS/\(name)", to: &standardError)
            for h in helperURLs { print("  helper: \(h.path) → Contents/Helpers/\(h.lastPathComponent)", to: &standardError) }
            var linked: [String] = []
            for binary in [executableURL] + helperURLs {
                for f in try Binary.linkedFrameworks(of: binary) where !linked.contains(f) {
                    linked.append(f)
                    print("  embeds: \(products.appending(path: f).path)", to: &standardError)
                }
            }
            if sparkle {
                print("  embeds: \(sparkleFramework.path) (Sparkle \(Appcast.sparkleToolsVersion); fetched first if missing)", to: &standardError)
            }
            for p in plugins { print("  plug-in: \(p)", to: &standardError) }
            if feed != nil, !sparkle, !linked.contains("Sparkle.framework") {
                print("\nnote: a real run of this would be refused — --feed with no Sparkle.framework (nothing links it; pass --sparkle if the app loads it at run time)", to: &standardError)
            }
            return
        }

        if sparkle {
            let executor = Executor { line in print(line, to: &standardError) }
            do {
                try executor.execute(.fetchToolsIfMissing(bin: toolsBin))
            } catch {
                print("ota: \(error)", to: &standardError)
                throw ExitCode(1)
            }
        }
        let app = try Bundler.assemble(input, into: outURL)
        if universal {
            for (binary, archs) in try Bundler.assertArchs(app, required: ["arm64", "x86_64"]) {
                print("  universal ✓ \(binary.lastPathComponent): \(archs.joined(separator: " "))", to: &standardError)
            }
        }
        print(outURL.path)
        let raised: String = raisedBy.map { " (raised by helper \($0.lastPathComponent))" } ?? ""
        let lane: String = feedSpec == nil ? "dev (no feed)" : "release (feed \(feed!))"
        print("bundle: \(name).app v\(version.marketing) build \(version.build), macOS ≥ \(minos)\(raised), \(lane)",
              to: &standardError)
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign, notarize, staple, zip, appcast, publish, then verify the live feed.",
        discussion: """
        The default lane is a real release: Developer ID + hardened runtime, \
        Apple notarization, the single-item appcast, both CDN keys overwritten \
        (the zip first), and a live-feed check as the last word. --no-publish \
        stops before the two `share` lines.

        --ad-hoc is the packaging test on THIS Mac: no Apple, no CDN, and it \
        refuses to publish. Give it --feed-dir to exercise the appcast into a \
        scratch directory without touching a real *-releases archive.
        """)

    @Argument(help: "The built .app") var app: String
    @Option(help: "CDN prefix (e.g. disk → disk/Disk-latest.zip + disk/appcast.xml).") var feed: String?
    @Option(help: "notarytool keychain profile.") var profile: String = "mux-notary"
    @Option(help: "Entitlements file for the app itself (Xcode apps).") var entitlements: String?
    @Option(name: .customLong("feed-dir"), help: "Local signing archive (default: ~/Library/Application Support/<feed>-releases).") var feedDir: String?
    @Flag(name: .customLong("ad-hoc"), help: "Ad-hoc sign; no notarization, never published. Packaging tests only.") var adHoc = false
    @Flag(name: .customLong("no-publish"), help: "Stop after the appcast; do not overwrite the CDN keys.") var noPublish = false
    @Flag(name: .customLong("dry-run"), help: "Print the plan — guards included — and stop.") var dryRun = false

    func run() throws {
        SelfID.announce()
        let bundle = AppBundle(URL(filePath: app))
        guard FileManager.default.fileExists(atPath: bundle.infoPlistURL.path) else {
            throw ValidationError("no bundle at \(app) (looked for \(bundle.infoPlistURL.path))")
        }

        let identity: Signing.Identity
        if adHoc {
            identity = .adHoc
        } else {
            guard let id = try Signing.developerID() else {
                throw ValidationError("no 'Developer ID Application' identity in the keychain — pass --ad-hoc for a packaging test")
            }
            identity = .developerID(id)
        }

        let marketing = try bundle.marketingVersion()
        let zip = URL(filePath: app).deletingLastPathComponent().appending(path: "\(bundle.name)-v\(marketing).zip")

        // The appcast lane: always for a real cut; for --ad-hoc only when a
        // scratch --feed-dir says so, so a packaging test can never merge
        // itself into a real signing archive.
        var target: OTAKit.Release.AppcastTarget?
        if !adHoc || feedDir != nil {
            guard let feed else { throw ValidationError("--feed is required to cut an appcast (e.g. --feed ccc)") }
            let dir = feedDir.map { URL(filePath: $0) }
                ?? URL.homeDirectory.appending(path: "Library/Application Support/\(feed)-releases")
            target = .init(feedDir: dir, prefixURL: Appcast.prefixURL(feed: feed),
                           cdnPrefix: feed, publish: !adHoc && !noPublish)
        }

        let release = OTAKit.Release(app: bundle, identity: identity, entitlements: entitlements, zip: zip,
                                     notaryProfile: adHoc ? nil : profile, appcast: target)
        try release.validate()
        let steps = release.steps()

        // An installed app is not a build product. A dry run against one is
        // fine — it only prints — but it says so, because the difference
        // between the two commands is one flag.
        let installedRefusal = OTAKit.Release.installedAppRefusal(for: bundle.url)
        guard !dryRun else {
            for step in steps { print(step) }
            if let installedRefusal {
                print("\nnote: a real run of this would be refused —\n\(installedRefusal)", to: &standardError)
            }
            return
        }
        if let installedRefusal { throw ValidationError(installedRefusal) }

        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let target {
            try FileManager.default.createDirectory(at: target.feedDir, withIntermediateDirectories: true)
        }
        let executor = Executor { line in print(line, to: &standardError) }
        do {
            try executor.execute(steps)
        } catch {
            print("ota: \(error)", to: &standardError)
            throw ExitCode(1)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? nil
        print(zip.path)
        print("cut \(bundle.name) v\(marketing)\(size.map { " (\($0) bytes)" } ?? "")"
              + (target?.publish == true ? ", published" : ", NOT published"), to: &standardError)
        if let target, !target.publish {
            print("publish it with:", to: &standardError)
            for step in Appcast.publishPlan(zip: zip, appcast: target.feedDir.appending(path: "appcast.xml"),
                                            prefix: target.cdnPrefix, appName: bundle.name) {
                print("  \(step)", to: &standardError)
            }
        }
    }
}

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a feed: live (--feed) that length= equals the zip's content-length, or local (--appcast) that it is single-item and points at the stable key.")

    @Option(help: "CDN prefix (e.g. disk) — fetches the live feed and the zip's headers.") var feed: String?
    @Option(help: "A local appcast.xml — the same single-item guard a release applies, before publishing.") var appcast: String?

    func run() throws {
        SelfID.announce()
        switch (feed, appcast) {
        case (let feed?, nil): try checkLive(feed)
        case (nil, let file?): try checkLocal(URL(filePath: file))
        default: throw ValidationError("pass exactly one of --feed <prefix> or --appcast <path>")
        }
    }

    /// The same `Step` a release runs, so what this reports and what a
    /// release refuses to publish can never drift apart.
    func checkLocal(_ file: URL) throws {
        let executor = Executor { line in print(line, to: &standardError) }
        do {
            try executor.execute(.requireSingleItem(appcast: file))
        } catch {
            print("ota: \(error)", to: &standardError)
            throw ExitCode(1)
        }
        guard let e = Feed.enclosure(xml: try String(contentsOf: file, encoding: .utf8)) else {
            print("ota: no enclosure in \(file.path)", to: &standardError)
            throw ExitCode(1)
        }
        print("ok: 1 item, \(e.url) version \(e.version ?? "?") length \(e.length)")
    }

    func checkLive(_ feed: String) throws {
        let prefix = Appcast.prefixURL(feed: feed)
        switch try Feed.checkLive(prefixURL: prefix) {
        case .ok(let e):
            print("ok: \(e.url) version \(e.version ?? "?") length \(e.length)")
        case .lengthMismatch(let feed, let live):
            print("MISMATCH: appcast says \(feed), live zip is \(live)")
            throw ExitCode(1)
        case .noEnclosure:
            print("no enclosure in \(prefix)appcast.xml")
            throw ExitCode(1)
        }
    }
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}
nonisolated(unsafe) var standardError = StandardError()
