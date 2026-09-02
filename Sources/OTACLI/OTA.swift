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
    static let line = "ota \(ownVersion) (scaffold)"
    static var ownVersion: String {
        // The VERSION file travels with the source; a frozen bin stamps it at install.
        let here = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: here.appending(path: "VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"
    }
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
    static let configuration = CommandConfiguration(abstract: "Assemble <name>.app from a SwiftPM release build (NOT WIRED: prints the spec).")

    @Option var name: String
    @Option(name: .customLong("bundle-id")) var bundleID: String
    @Option(name: .customLong("display-name")) var displayName: String?
    @Option(help: "CDN prefix for self-update (e.g. ccc). Omit for the dev lane: no SUFeedURL, no Sparkle at runtime.") var feed: String?
    @Option(help: "Sparkle EdDSA public key (required with --feed).") var publicKey: String?
    @Option(help: "Repo root (default: cwd).") var repo: String = FileManager.default.currentDirectoryPath

    func run() throws {
        SelfID.announce()
        let repoURL = URL(filePath: repo)
        let version = try OTAKit.Version.read(repo: repoURL)
        let binary = repoURL.appending(path: ".build/release/\(name)")
        let minos = try Binary.minos(of: binary)
        var feedSpec: BundleSpec.Feed?
        if let feed {
            guard let publicKey else { throw ValidationError("--feed needs --public-key") }
            feedSpec = .init(url: "https://cdn.ramonfabrega.com/\(feed)/appcast.xml", publicEDKey: publicKey)
        }
        let spec = BundleSpec(name: name, displayName: displayName, bundleID: bundleID, version: version,
                              minimumSystemVersion: minos, feed: feedSpec)
        print(String(decoding: try spec.infoPlistXML(), as: UTF8.self))
        print("linked frameworks: \(try Binary.linkedFrameworks(of: binary))", to: &standardError)
        print("bundle assembly is not wired yet — see CLAUDE.md, first session", to: &standardError)
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sign, notarize, staple, zip, appcast, publish (NOT WIRED: --dry-run prints the plan).")

    @Argument(help: "The built .app") var app: String
    @Option(help: "CDN prefix (e.g. disk → disk/Disk-latest.zip + disk/appcast.xml).") var feed: String
    @Option(help: "notarytool keychain profile.") var profile: String = "mux-notary"
    @Option(help: "Entitlements file for the app itself (Xcode apps).") var entitlements: String?
    @Flag(help: "Ad-hoc sign, no notarization, no appcast. Packaging tests only.") var adHoc = false
    @Flag(name: .customLong("dry-run"), help: "Print the plan and stop.") var dryRun = false

    func run() throws {
        SelfID.announce()
        let appURL = URL(filePath: app)
        let name = appURL.deletingPathExtension().lastPathComponent
        let identity: Signing.Identity
        if adHoc {
            identity = .adHoc
        } else {
            guard let id = try Signing.developerID() else {
                throw ValidationError("no 'Developer ID Application' identity in the keychain — pass --ad-hoc for a test package")
            }
            identity = .developerID(id)
        }
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: appURL.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any]
        let marketing = plist?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let dist = appURL.deletingLastPathComponent()
        let zip = dist.appending(path: "\(name)-v\(marketing).zip")
        let feedDir = URL.homeDirectory.appending(path: "Library/Application Support/\(feed)-releases")
        let prefixURL = "https://cdn.ramonfabrega.com/\(feed)/"

        var plan = Signing.plan(Signing.insideOut(app: appURL, entitlements: entitlements), identity: identity)
        if adHoc {
            plan.append(Notarize.zip(app: appURL, to: zip))
        } else {
            plan += Notarize.plan(app: appURL, zip: zip, profile: profile)
            plan += Appcast.generatePlan(feedDir: feedDir, currentZip: zip, prefixURL: prefixURL, toolsBin: Appcast.toolsBin())
            plan += Appcast.publishPlan(zip: zip, appcast: feedDir.appending(path: "appcast.xml"), prefix: feed, appName: name)
        }
        for c in plan { print(c) }
        guard !dryRun else { return }
        print("execution is not wired yet — see CLAUDE.md, first session; use --dry-run", to: &standardError)
        throw ExitCode(2)
    }
}

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fetch the live appcast and zip headers; the feed's length= must equal the zip's content-length.")

    @Option(help: "CDN prefix (e.g. disk).") var feed: String

    func run() throws {
        SelfID.announce()
        let base = "https://cdn.ramonfabrega.com/\(feed)/"
        let xml = try String(contentsOf: URL(string: base + "appcast.xml")!, encoding: .utf8)
        guard let enclosure = Feed.enclosure(xml: xml) else { throw ValidationError("no enclosure in \(base)appcast.xml") }
        var head = URLRequest(url: URL(string: enclosure.url)!)
        head.httpMethod = "HEAD"
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var live = -1
        URLSession.shared.dataTask(with: head) { _, response, _ in
            live = Int((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
            semaphore.signal()
        }.resume()
        semaphore.wait()
        switch Feed.check(appcastXML: xml, liveContentLength: live) {
        case .ok(let e): print("ok: \(e.url) version \(e.version ?? "?") length \(e.length)")
        case .lengthMismatch(let feed, let live): print("MISMATCH: appcast says \(feed), live zip is \(live)"); throw ExitCode(1)
        case .noEnclosure: throw ExitCode(1)
        }
    }
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}
nonisolated(unsafe) var standardError = StandardError()
