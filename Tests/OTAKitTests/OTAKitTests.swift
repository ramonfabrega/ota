import Foundation
import Testing
@testable import OTAKit

@Suite struct BinaryFacts {
    @Test func minosComesFromBuildVersionOnly() {
        let otool = """
        Load command 9
              cmd LC_VERSION_MIN_MACOSX
              version 10.13
        Load command 10
              cmd LC_BUILD_VERSION
          cmdsize 32
         platform 1
            minos 26.0
              sdk 26.0
        """
        #expect(Binary.minos(fromLoadCommands: otool) == "26.0")
        #expect(Binary.minos(fromLoadCommands: "Load command 0\n cmd LC_SEGMENT_64") == nil)
    }

    @Test func linkedFrameworksAreOnlyEmbeddedOnes() {
        let otoolL = """
        .build/release/ccc:
        \t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.0.0, current version 2.9.4)
        \t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0)
        \t@executable_path/../Frameworks/Engine.framework/Versions/A/Engine (compatibility version 1.0.0)
        \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
        """
        #expect(Binary.linkedFrameworks(fromOtoolL: otoolL) == ["Sparkle.framework", "Engine.framework"])
    }

    @Test func archs() {
        #expect(Binary.archs(fromLipo: "x86_64 arm64 \n") == ["x86_64", "arm64"])
    }
}

@Suite struct Versioning {
    @Test func semver() {
        #expect(Version.isSemver("0.1.4"))
        #expect(!Version.isSemver("v0.1.4"))
        #expect(!Version.isSemver("0.1"))
    }

    /// `otaVersion` is compiled into the binary because an installed copy
    /// cannot read the repo's `VERSION`; this is the one place the two are
    /// held to each other. The test may use `#filePath` — a test DOES run
    /// from the source tree.
    @Test func compiledVersionMatchesTheVersionFile() throws {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: repo.appending(path: "VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(otaVersion == file, "bump otaVersion in Sources/OTAKit/OTAVersion.swift alongside VERSION")
    }
}

@Suite struct Plist {
    @Test func devLaneHasNoFeed() throws {
        let spec = BundleSpec(name: "ccc", bundleID: "com.ramonfabrega.ccc",
                              version: Version(marketing: "0.1.4", build: 53), minimumSystemVersion: "26.0")
        let plist = spec.infoPlist
        #expect(plist["SUFeedURL"] == nil)
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(plist["CFBundleVersion"] as? String == "53")
        #expect(plist["CFBundleDisplayName"] as? String == "ccc")
        let xml = String(decoding: try spec.infoPlistXML(), as: UTF8.self)
        #expect(xml.contains("<key>CFBundleExecutable</key>"))
    }

    @Test func releaseLaneCarriesSparkleKeys() {
        let spec = BundleSpec(name: "Disk", displayName: "Disk", bundleID: "com.ramonfabrega.disk",
                              version: Version(marketing: "0.6.0", build: 120), minimumSystemVersion: "14.0",
                              feed: .init(url: "https://cdn.ramonfabrega.com/disk/appcast.xml", publicEDKey: "KEY"))
        let plist = spec.infoPlist
        #expect(plist["SUFeedURL"] as? String == "https://cdn.ramonfabrega.com/disk/appcast.xml")
        #expect(plist["SUPublicEDKey"] as? String == "KEY")
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
    }
}

// MARK: - a fake .app under the temp dir, shared by the plan suites

func fakeApp(widget: Bool, publicEDKey: String? = nil, version: String = "1.2.3") throws -> URL {
    let fm = FileManager.default
    let app = fm.temporaryDirectory.appending(path: "ota-\(UUID().uuidString)/Fake.app")
    for dir in ["Contents/MacOS",
                "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc",
                "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc",
                "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"] {
        try fm.createDirectory(at: app.appending(path: dir), withIntermediateDirectories: true)
    }
    fm.createFile(atPath: app.appending(path: "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate").path, contents: Data())
    if widget {
        try fm.createDirectory(at: app.appending(path: "Contents/PlugIns/FakeWidget.appex"), withIntermediateDirectories: true)
    }
    var plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleExecutable": "Fake"]
    if let publicEDKey { plist["SUPublicEDKey"] = publicEDKey }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: app.appending(path: "Contents/Info.plist"))
    return app
}

@Suite struct SigningOrder {
    @Test func sparkleFirstThenFrameworksThenPluginsThenApp() throws {
        let app = try fakeApp(widget: true)
        let steps = Signing.insideOut(app: app)
        let tails = steps.map { URL(filePath: $0.path).lastPathComponent }
        #expect(tails == ["Installer.xpc", "Downloader.xpc", "Autoupdate", "Updater.app", "Sparkle.framework", "FakeWidget.appex", "Fake.app"])
        #expect(steps[1].preserveEntitlements)   // Downloader keeps its sandbox
        #expect(steps[5].preserveEntitlements)   // the appex keeps app-sandbox
        #expect(!steps[4].preserveEntitlements)
    }

    @Test func planEndsWithStrictVerify() throws {
        let app = try fakeApp(widget: false)
        let plan = Signing.plan(Signing.insideOut(app: app, entitlements: "App.entitlements"), identity: .developerID("Developer ID Application: X (TEAM)"))
        #expect(plan.last == Command("codesign", "--verify", "--deep", "--strict", "--verbose=2", app.path))
        let appSign = plan[plan.count - 2]
        #expect(appSign.arguments.contains("--options"))
        #expect(appSign.arguments.contains("runtime"))
        #expect(appSign.arguments.contains("App.entitlements"))
    }

    @Test func developerIDParses() {
        let out = """
          1) ABC123 "Apple Development: Ramon (TEAM)"
          2) DEF456 "Developer ID Application: Ramon Fabrega (GJYB)"
             2 valid identities found
        """
        #expect(Signing.developerID(fromFindIdentity: out) == "Developer ID Application: Ramon Fabrega (GJYB)")
        #expect(Signing.developerID(fromFindIdentity: "0 valid identities found") == nil)
    }
}

@Suite struct AppcastFeed {
    /// A real Sparkle 2 item: `sparkle:version` is a CHILD ELEMENT, not an
    /// enclosure attribute. Copied from the live ccc feed.
    let xml = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>disk</title>
    <item><title>0.6.0</title>
    <sparkle:version>120</sparkle:version>
    <sparkle:shortVersionString>0.6.0</sparkle:shortVersionString>
    <enclosure url="https://cdn.ramonfabrega.com/disk/Disk-v0.6.0.zip" length="4400000" type="application/octet-stream" sparkle:edSignature="sig"/>
    </item></channel></rss>
    """

    /// One prefix feeds the app's `SUFeedURL`, the generated enclosure and
    /// the live check. They were three separate literals in the CLI, which is
    /// three chances to publish under one host and verify under another.
    @Test func onePrefixServesFeedEnclosureAndCheck() {
        let prefix = Appcast.prefixURL(feed: "ccc")
        #expect(prefix == Appcast.cdnBaseURL + "ccc/")
        #expect(prefix.hasSuffix("/"))
        #expect(Appcast.stableKey(prefixURL: prefix, appName: "ccc") == prefix + "ccc-latest.zip")
    }

    @Test func stableKeyRewrite() {
        let out = Appcast.rewriteToStableKey(xml: xml, prefixURL: "https://cdn.ramonfabrega.com/disk/", appName: "Disk")
        #expect(out.contains("url=\"https://cdn.ramonfabrega.com/disk/Disk-latest.zip\""))
        #expect(!out.contains("Disk-v0.6.0.zip"))
        #expect(Appcast.itemCount(xml: out) == 1)
    }

    @Test func versionIsReadFromTheChildElement() {
        #expect(Feed.enclosure(xml: xml)?.version == "120")
        // …and still from the attribute, where a generator puts it there.
        let attributed = "<enclosure url=\"https://x/A-v1.zip\" length=\"9\" sparkle:version=\"7\"/>"
        #expect(Feed.enclosure(xml: attributed)?.version == "7")
    }

    @Test func lengthMustMatchLive() {
        #expect(Feed.check(appcastXML: xml, liveContentLength: 4_400_000)
                == .ok(Feed.Enclosure(url: "https://cdn.ramonfabrega.com/disk/Disk-v0.6.0.zip", length: 4_400_000, version: "120")))
        #expect(Feed.check(appcastXML: xml, liveContentLength: 3_200_000) == .lengthMismatch(feed: 4_400_000, live: 3_200_000))
        #expect(Feed.check(appcastXML: "<rss/>", liveContentLength: 1) == .noEnclosure)
    }

    @Test func notarizeRezipsAfterStaple() {
        let plan = Notarize.plan(app: URL(filePath: "/x/A.app"), zip: URL(filePath: "/x/A-v1.zip"), profile: "notary")
        #expect(plan.first == .run(Notarize.zip(app: URL(filePath: "/x/A.app"), to: URL(filePath: "/x/A-v1.zip"))))
        #expect(plan.last == plan.first)
        #expect(plan.contains(.stream(Command("xcrun", "stapler", "staple", "/x/A.app"))))
        // The long, chatty ones stream; the quiet ones are captured.
        #expect(plan.contains(.stream(Command("xcrun", "notarytool", "submit", "/x/A-v1.zip", "--keychain-profile", "notary", "--wait"))))
    }

    @Test func generateStartsFromEmptyAndArchivesEveryOtherZip() {
        let plan = Appcast.generatePlan(feedDir: URL(filePath: "/f"), currentZip: URL(filePath: "/d/A-v1.zip"),
                                        prefixURL: "https://cdn/a/", toolsBin: URL(filePath: "/t"))
        #expect(plan.contains(.run(Command("rm", "-f", "/f/appcast.xml"))))
        // Any *.zip, not just A-v*.zip: generate_appcast scans the directory.
        #expect(plan.contains(.run(Command("find", ["/f", "-maxdepth", "1", "-name", "*.zip", "!", "-name", "A-v1.zip",
                                                    "-exec", "mv", "{}", "/f/old_updates/", ";"]))))
        guard case .stream(let generate)? = plan.last else { Issue.record("generate_appcast must stream"); return }
        #expect(generate.arguments.contains("--maximum-versions"))
    }

    @Test func toolsFetchUsesNoShell() {
        let plan = Appcast.fetchToolsPlan(into: URL(filePath: "/c/2.9.4/bin"))
        #expect(!plan.contains { $0.program == "sh" || $0.program == "zsh" || $0.program == "bash" })
        #expect(plan.contains { $0.program == "curl" && $0.arguments.contains("-o") })
        #expect(plan.contains { $0.program == "tar" && $0.arguments.contains("-xJf") })
    }

    @Test func zipIsPublishedBeforeTheAppcast() {
        let plan = Appcast.publishPlan(zip: URL(filePath: "/d/A-v1.zip"), appcast: URL(filePath: "/f/appcast.xml"),
                                       prefix: "a", appName: "A")
        // The window between the two writes must be "key new, feed old" —
        // the order that no installed copy acts on.
        #expect(plan == [.stream(Command("share", "/d/A-v1.zip", "a/A-latest.zip", "--permanent")),
                         .stream(Command("share", "/f/appcast.xml", "a/appcast.xml", "--permanent"))])
    }
}

// MARK: - the plan as a whole

@Suite struct ReleasePlan {
    func release(adHoc: Bool, publish: Bool, appcast: Bool = true) throws -> OTAKit.Release {
        let app = try fakeApp(widget: false, publicEDKey: "PINNED")
        return OTAKit.Release(
            app: AppBundle(app),
            identity: adHoc ? .adHoc : .developerID("Developer ID Application: R (TEAM)"),
            zip: URL(filePath: "/d/Fake-v1.2.3.zip"),
            notaryProfile: adHoc ? nil : "mux-notary",
            appcast: appcast ? .init(feedDir: URL(filePath: "/f"), prefixURL: "https://cdn.ramonfabrega.com/x/",
                                     cdnPrefix: "x", publish: publish) : nil,
            toolsBin: URL(filePath: "/t"))
    }

    /// The guards are IN the plan, and in the order that makes them worth
    /// having: the key match before the first signature, the item count
    /// before the rewrite, the live check last.
    @Test func guardsBookendTheCommands() throws {
        let steps = try release(adHoc: false, publish: true).steps()
        let firstCodesign = try #require(steps.firstIndex { if case .run(let c) = $0 { return c.program == "codesign" }; return false })
        let keyGuard = try #require(steps.firstIndex { if case .requireEdDSAKeyMatch = $0 { return true }; return false })
        let itemGuard = try #require(steps.firstIndex { if case .requireSingleItem = $0 { return true }; return false })
        let rewrite = try #require(steps.firstIndex { if case .rewriteToStableKey = $0 { return true }; return false })
        #expect(keyGuard < firstCodesign)
        #expect(itemGuard < rewrite)
        guard case .checkLiveFeed = steps.last else { Issue.record("the live-feed check must be the last word"); return }
    }

    @Test func adHocRefusesToPublish() throws {
        #expect(throws: OTAKit.Release.ConfigurationError.self) {
            try release(adHoc: true, publish: true).validate()
        }
        // …and is fine as a packaging test into a scratch feed dir.
        try release(adHoc: true, publish: false).validate()
    }

    /// The input is a build product. Signing is in place and the zip lands
    /// beside the bundle, so a real run against an installed app re-signs
    /// what you are running and publishes it — and `/Applications/Disk.app`
    /// is the documented dry-run demo, one flag away from that.
    @Test func anInstalledAppIsRefused() {
        let home = URL(filePath: "/Users/x")
        #expect(OTAKit.Release.installedAppRefusal(for: URL(filePath: "/Applications/Disk.app"), home: home) != nil)
        #expect(OTAKit.Release.installedAppRefusal(for: URL(filePath: "/Applications/Utilities/Disk.app"), home: home) != nil)
        #expect(OTAKit.Release.installedAppRefusal(for: URL(filePath: "/Users/x/Applications/ccc.app"), home: home) != nil)

        // A build product is what it is for, wherever the repo lives.
        #expect(OTAKit.Release.installedAppRefusal(for: URL(filePath: "/Users/x/code/ccc/.build/dist/ccc.app"), home: home) == nil)
        #expect(OTAKit.Release.installedAppRefusal(for: URL(filePath: "/tmp/scratch/ccc.app"), home: home) == nil)
        // Not fooled by a prefix that merely starts the same way.
        #expect(OTAKit.Release.installedAppRefusal(for: URL(filePath: "/ApplicationsOfMine/ccc.app"), home: home) == nil)
        // …nor by a path that walks back out of it.
        #expect(OTAKit.Release.installedAppRefusal(for: URL(filePath: "/Applications/../build/ccc.app"), home: home) == nil)
    }

    @Test func noAppcastMeansNoGuardsAndNoPublish() throws {
        let steps = try release(adHoc: true, publish: false, appcast: false).steps()
        #expect(!steps.contains { if case .requireEdDSAKeyMatch = $0 { return true }; return false })
        #expect(!steps.contains { if case .checkLiveFeed = $0 { return true }; return false })
        #expect(!steps.contains { if case .stream(let c) = $0 { return c.program == "share" }; return false })
        // It still cuts a --sequesterRsrc zip.
        guard case .run(let ditto)? = steps.last else { Issue.record("expected a ditto"); return }
        #expect(ditto.arguments.contains("--sequesterRsrc"))
    }
}

// MARK: - the guards, made to fire

/// Canned stdout per program; records what it was asked to run.
final class FakeRunner: Runner, @unchecked Sendable {
    var output: [String: String]
    private(set) var ran: [Command] = []
    init(output: [String: String] = [:]) { self.output = output }

    func run(_ command: Command, streaming: Bool) throws -> String {
        ran.append(command)
        return output[URL(filePath: command.program).lastPathComponent] ?? ""
    }
}

@Suite struct Guards {
    func executor(_ runner: Runner) -> Executor {
        Executor(runner: runner, log: { _ in })
    }

    func write(_ xml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "appcast.xml")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func eddsaMismatchAbortsBeforeSigning() throws {
        let app = try fakeApp(widget: false, publicEDKey: "PINNED")
        let runner = FakeRunner(output: ["generate_keys": "OTHER\n"])
        let error = #expect(throws: Executor.StepFailure.self) {
            try executor(runner).execute(.requireEdDSAKeyMatch(app: app, toolsBin: URL(filePath: "/t")))
        }
        #expect(error?.description.contains("SUPublicEDKey mismatch: Keychain OTHER vs app PINNED") == true)
        #expect(error?.description.contains("REJECTED") == true)
    }

    @Test func matchingKeyPasses() throws {
        let app = try fakeApp(widget: false, publicEDKey: "PINNED")
        let runner = FakeRunner(output: ["generate_keys": "PINNED\n"])
        try executor(runner).execute(.requireEdDSAKeyMatch(app: app, toolsBin: URL(filePath: "/t")))
        #expect(runner.ran == [Command("/t/generate_keys", "-p")])
    }

    /// A dev-lane bundle pins no key, so it can never accept an update —
    /// releasing one is a mistake worth its own message.
    @Test func devLaneBundleIsRefused() throws {
        let app = try fakeApp(widget: false, publicEDKey: nil)
        let error = #expect(throws: Executor.StepFailure.self) {
            try executor(FakeRunner()).execute(.requireEdDSAKeyMatch(app: app, toolsBin: URL(filePath: "/t")))
        }
        #expect(error?.description.contains("DEV-lane bundle") == true)
    }

    @Test func twoItemsAbort() throws {
        let two = "<rss><channel><item>a</item><item>b</item></channel></rss>"
        let error = #expect(throws: Executor.StepFailure.self) {
            try executor(FakeRunner()).execute(.requireSingleItem(appcast: try write(two)))
        }
        #expect(error?.description.contains("appcast has 2 items, expected 1") == true)
    }

    @Test func oneItemPasses() throws {
        try executor(FakeRunner()).execute(.requireSingleItem(appcast: try write("<rss><item>a</item></rss>")))
    }

    @Test func rewriteWritesTheFileAndRefusesAMiss() throws {
        let file = try write("""
        <rss><item><enclosure url="https://cdn.ramonfabrega.com/x/Fake-v1.2.3.zip" length="7"/></item></rss>
        """)
        try executor(FakeRunner()).execute(.rewriteToStableKey(appcast: file, prefixURL: "https://cdn.ramonfabrega.com/x/", appName: "Fake"))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Fake-latest.zip"))

        // A feed whose enclosure never matched the expected shape must not
        // pass silently: the stable key would then point at nothing.
        let wrong = try write("<rss><item><enclosure url=\"https://elsewhere/Other.zip\" length=\"7\"/></item></rss>")
        #expect(throws: Executor.StepFailure.self) {
            try executor(FakeRunner()).execute(.rewriteToStableKey(appcast: wrong, prefixURL: "https://cdn.ramonfabrega.com/x/", appName: "Fake"))
        }
    }

    struct StubFetcher: Feed.Fetcher {
        var xml: String
        var length: Int
        func text(at url: String) throws -> String { xml }
        func contentLength(at url: String) throws -> Int { length }
    }

    @Test func liveFeedMismatchIsLoud() throws {
        let xml = "<rss><item><enclosure url=\"https://cdn/x/A-latest.zip\" length=\"100\"/></item></rss>"
        let ex = Executor(runner: FakeRunner(), fetcher: StubFetcher(xml: xml, length: 99), log: { _ in })
        let error = #expect(throws: Executor.StepFailure.self) {
            try ex.execute(.checkLiveFeed(prefixURL: "https://cdn/x/"))
        }
        #expect(error?.description.contains("LIVE FEED MISMATCH") == true)

        let ok = Executor(runner: FakeRunner(), fetcher: StubFetcher(xml: xml, length: 100), log: { _ in })
        try ok.execute(.checkLiveFeed(prefixURL: "https://cdn/x/"))
    }
}

@Suite struct BundleAssembly {
    let spec = BundleSpec(name: "Fake", bundleID: "com.example.fake",
                          version: Version(marketing: "1.2.3", build: 42), minimumSystemVersion: "14.0",
                          iconFile: "AppIcon")

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SwiftPM's multi-arch build emits elsewhere, and reading `.build/release`
    /// for a universal cut is how a release ships thin without saying so.
    @Test func universalReadsTheLipodProductsDir() {
        let repo = URL(filePath: "/r")
        #expect(Bundler.productsDirectory(repo: repo, universal: false).path == "/r/.build/release")
        #expect(Bundler.productsDirectory(repo: repo, universal: true).path == "/r/.build/apple/Products/Release")
    }

    @Test func placesBinaryIconPluginAndPlist() throws {
        let dir = try scratch()
        let products = dir.appending(path: "products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        // A real Mach-O, so `otool -L` has something to answer about.
        let executable = products.appending(path: "FakeApp")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: executable)
        let icon = dir.appending(path: "AppIcon.icns")
        try Data("icns".utf8).write(to: icon)

        // An .appex shipping a static version: WidgetKit keys its widget-kind
        // cache on the bundle version, so this must come out stamped.
        let appex = dir.appending(path: "FakeWidget.appex")
        try FileManager.default.createDirectory(at: appex.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "1", "CFBundleShortVersionString": "1"],
                                           format: .xml, options: 0)
            .write(to: appex.appending(path: "Contents/Info.plist"))

        let out = dir.appending(path: "Fake.app")
        let app = try Bundler.assemble(.init(spec: spec, executable: executable, productsDirectory: products,
                                             icon: icon, plugins: [appex]), into: out)

        let fm = FileManager.default
        #expect(fm.isExecutableFile(atPath: out.appending(path: "Contents/MacOS/Fake").path))
        #expect(fm.fileExists(atPath: out.appending(path: "Contents/Resources/AppIcon.icns").path))
        #expect(try app.marketingVersion() == "1.2.3")
        #expect(try app.publicEDKey() == nil)   // no --feed: the dev lane

        let widgetPlist = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: out.appending(path: "Contents/PlugIns/FakeWidget.appex/Contents/Info.plist")),
            format: nil) as? [String: Any]
        #expect(widgetPlist?["CFBundleVersion"] as? String == "42")
        #expect(widgetPlist?["CFBundleShortVersionString"] as? String == "1.2.3")
    }

    /// What the binary links must be embedded, and the binary is the one that
    /// knows. A missing framework is a launch failure on someone else's Mac.
    @Test func linkedButUnembeddedFrameworkIsRefused() throws {
        let dir = try scratch()
        let products = dir.appending(path: "products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let executable = products.appending(path: "FakeApp")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: executable)
        let runner = FakeRunner(output: ["otool": """
        \(executable.path):
        \t@rpath/Sparkle.framework/Versions/B/Sparkle (compatibility version 1.0.0)
        """])
        let error = #expect(throws: Bundler.Error.self) {
            try Bundler.assemble(.init(spec: spec, executable: executable, productsDirectory: products),
                                 into: dir.appending(path: "Fake.app"), runner: runner)
        }
        #expect(error?.description.contains("links Sparkle.framework but there is none") == true)
    }

    @Test func archAssertionCoversEveryMachOAndRefusesAnEmptyBundle() throws {
        let dir = try scratch()
        let products = dir.appending(path: "products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        let executable = products.appending(path: "FakeApp")
        try FileManager.default.copyItem(at: URL(filePath: "/bin/echo"), to: executable)
        let out = dir.appending(path: "Fake.app")
        let app = try Bundler.assemble(.init(spec: spec, executable: executable, productsDirectory: products), into: out)

        // /bin/echo is not built for this: the point is that the assertion
        // reads real archs off a real Mach-O and names what is missing.
        let error = #expect(throws: Bundler.Error.self) {
            try Bundler.assertArchs(app, required: ["arm64", "ppc"])
        }
        #expect(error?.description.contains("NOT UNIVERSAL") == true)
        #expect(error?.description.contains("ppc") == true)

        // Finding nothing is not the same as passing.
        let empty = dir.appending(path: "Empty.app")
        try FileManager.default.createDirectory(at: empty.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        #expect(throws: Bundler.Error.self) {
            try Bundler.assertArchs(AppBundle(empty), required: ["arm64"])
        }
    }
}

@Suite struct RunnerBehaviour {
    /// Draining one pipe to EOF before the other deadlocks as soon as the
    /// child fills the 64K kernel buffer on the pipe nobody is reading. This
    /// child writes 200K to stderr FIRST and then 200K to stdout, so a
    /// sequential reader blocks forever. If this test hangs, that is the bug.
    @Test func bothPipesAreDrainedConcurrently() throws {
        let noisy = Command("sh", "-c", "dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'e' >&2; dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'o'")
        let out = try SystemRunner().run(noisy)
        #expect(out.count == 200 * 1024)
    }

    @Test func nonZeroExitCarriesStderr() {
        let error = #expect(throws: CommandFailure.self) {
            try SystemRunner().run(Command("sh", "-c", "echo boom >&2; exit 3"))
        }
        #expect(error?.status == 3)
        #expect(error?.stderr == "boom")
    }
}
