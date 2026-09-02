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

@Suite struct SigningOrder {
    func fakeApp(widget: Bool) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(path: "ota-\(UUID().uuidString)/Fake.app")
        let fm = FileManager.default
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
        return app
    }

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
    let xml = """
    <rss><channel><item><title>0.6.0</title>
    <enclosure url="https://cdn.ramonfabrega.com/disk/Disk-v0.6.0.zip" length="4400000" type="application/octet-stream" sparkle:version="120" sparkle:shortVersionString="0.6.0" sparkle:edSignature="sig"/>
    </item></channel></rss>
    """

    @Test func stableKeyRewrite() {
        let out = Appcast.rewriteToStableKey(xml: xml, prefixURL: "https://cdn.ramonfabrega.com/disk/", appName: "Disk")
        #expect(out.contains("url=\"https://cdn.ramonfabrega.com/disk/Disk-latest.zip\""))
        #expect(!out.contains("Disk-v0.6.0.zip"))
        #expect(Appcast.itemCount(xml: out) == 1)
    }

    @Test func lengthMustMatchLive() {
        #expect(Feed.check(appcastXML: xml, liveContentLength: 4_400_000) == .ok(Feed.Enclosure(url: "https://cdn.ramonfabrega.com/disk/Disk-v0.6.0.zip", length: 4_400_000, version: "120")))
        #expect(Feed.check(appcastXML: xml, liveContentLength: 3_200_000) == .lengthMismatch(feed: 4_400_000, live: 3_200_000))
        #expect(Feed.check(appcastXML: "<rss/>", liveContentLength: 1) == .noEnclosure)
    }

    @Test func notarizeRezipsAfterStaple() {
        let plan = Notarize.plan(app: URL(filePath: "/x/A.app"), zip: URL(filePath: "/x/A-v1.zip"), profile: "notary")
        #expect(plan.first?.arguments.contains("--sequesterRsrc") == true)
        #expect(plan.last == plan.first)
        #expect(plan.contains(Command("xcrun", "stapler", "staple", "/x/A.app")))
    }

    @Test func generateStartsFromEmpty() {
        let plan = Appcast.generatePlan(feedDir: URL(filePath: "/f"), currentZip: URL(filePath: "/d/A-v1.zip"),
                                        prefixURL: "https://cdn/a/", toolsBin: URL(filePath: "/t"))
        #expect(plan.contains(Command("rm", "-f", "/f/appcast.xml")))
        #expect(plan.last?.arguments.contains("--maximum-versions") == true)
    }
}
