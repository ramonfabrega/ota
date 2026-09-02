import Foundation

/// One step of a release plan.
///
/// The flow is not a flat list of processes: three of its steps are not
/// processes at all (the EdDSA key-match guard, the single-item assertion,
/// the stable-key rewrite — the shell copies did that last one with `sed`,
/// which is why they could pretend it was one) and one is conditional (fetch
/// Sparkle's tools only when they are missing). A plan of `[Command]` can
/// therefore only ever print the parts that are not the guards — and the
/// guards are the whole reason disk's copy of this script is better than
/// mux's. So the plan is a list of `Step`, `Command` stays the leaf, and
/// `--dry-run` prints the guards where they fire.
public enum Step: Equatable, Sendable, CustomStringConvertible {
    /// Run it, capture its output. The parsers and the quiet, fast tools.
    case run(Command)
    /// Run it, hand it the terminal. The minutes-long, chatty ones.
    case stream(Command)
    /// Fetch Sparkle's tools when `bin` has none, and never otherwise.
    case fetchToolsIfMissing(bin: URL)
    /// `generate_keys -p` must equal the app's pinned `SUPublicEDKey`, or
    /// every update this cut signs is rejected on the receiving Mac. Before
    /// the first signature, because a mismatch invalidates the whole cut.
    case requireEdDSAKeyMatch(app: URL, toolsBin: URL)
    /// Exactly one `<item>`, or the feed is lying about at least one of them.
    case requireSingleItem(appcast: URL)
    /// Repoint the enclosure at the stable key.
    case rewriteToStableKey(appcast: URL, prefixURL: String, appName: String)
    /// Fetch what Sparkle will fetch and compare `length=` to the zip's live
    /// `content-length`. Last step of a release; a failure here is the only
    /// thing standing between a half-published pair and silence.
    case checkLiveFeed(prefixURL: String)

    public var description: String {
        switch self {
        case .run(let c), .stream(let c):
            return c.description
        case .fetchToolsIfMissing(let bin):
            return "# if missing: fetch Sparkle \(Appcast.sparkleToolsVersion) tools → \(bin.path)"
        case .requireEdDSAKeyMatch(let app, let toolsBin):
            return "# require: \(toolsBin.appending(path: "generate_keys").path) -p == SUPublicEDKey of \(app.lastPathComponent)"
        case .requireSingleItem(let appcast):
            return "# require: exactly one <item> in \(appcast.path)"
        case .rewriteToStableKey(let appcast, let prefixURL, let appName):
            return "# rewrite: \(appcast.lastPathComponent) enclosure url → \(Appcast.stableKey(prefixURL: prefixURL, appName: appName))"
        case .checkLiveFeed(let prefixURL):
            return "# require: live \(prefixURL)appcast.xml length= == the live zip's content-length"
        }
    }
}

/// Everything downstream of a built `.app`, as a value.
public struct Release: Sendable {
    public var app: AppBundle
    public var identity: Signing.Identity
    /// An entitlements file for the app itself (Xcode apps; mux).
    public var entitlements: String?
    /// Where the versioned zip is written.
    public var zip: URL
    /// `nil` skips Apple entirely — the ad-hoc packaging lane, which never
    /// ships across machines.
    public var notaryProfile: String?
    /// `nil` cuts a zip and stops.
    public var appcast: AppcastTarget?
    public var toolsBin: URL

    public struct AppcastTarget: Sendable, Equatable {
        /// The local signing archive, e.g. `~/Library/Application Support/ccc-releases`.
        public var feedDir: URL
        /// `https://cdn.ramonfabrega.com/ccc/`.
        public var prefixURL: String
        /// `ccc` — the CDN key prefix `share` writes under.
        public var cdnPrefix: String
        /// Run the two `share` lines and then check the live feed.
        public var publish: Bool

        public init(feedDir: URL, prefixURL: String, cdnPrefix: String, publish: Bool) {
            self.feedDir = feedDir
            self.prefixURL = prefixURL
            self.cdnPrefix = cdnPrefix
            self.publish = publish
        }
    }

    public init(app: AppBundle, identity: Signing.Identity, entitlements: String? = nil, zip: URL,
                notaryProfile: String?, appcast: AppcastTarget?, toolsBin: URL = Appcast.toolsBin()) {
        self.app = app
        self.identity = identity
        self.entitlements = entitlements
        self.zip = zip
        self.notaryProfile = notaryProfile
        self.appcast = appcast
        self.toolsBin = toolsBin
    }

    public struct ConfigurationError: Error, CustomStringConvertible {
        public var description: String
    }

    /// A release's input is a BUILD PRODUCT, and this refuses an installed
    /// app. Signing happens in place and the zip is written beside the
    /// bundle, so pointing a real run at `/Applications/Disk.app` re-signs
    /// the copy you are running, drops a zip into `/Applications`, and then
    /// publishes it over the current release. Nothing downstream would stop
    /// it: the EdDSA guard passes, because it is the real key.
    ///
    /// `/Applications/Disk.app` is also the documented `--dry-run` demo,
    /// which is precisely why it is the most likely path to be typed one day
    /// without the flag. Returns the reason, or `nil` when the path is fine.
    public static func installedAppRefusal(for app: URL, home: URL = .homeDirectory) -> String? {
        let path = app.standardizedFileURL.path
        let installed = ["/Applications", home.appending(path: "Applications").standardizedFileURL.path]
        guard installed.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
        return """
            \(path) is an INSTALLED app, not a build product — refusing.

            A release signs the bundle in place and writes the zip beside it, so this would \
            re-sign the copy you are running, leave a zip in \(app.deletingLastPathComponent().path), \
            and publish it over the current release. Point it at the bundle your build just made \
            (\(app.deletingPathExtension().lastPathComponent.lowercased())'s scripts/package puts one in .build/dist/).

            --dry-run against this path is still allowed; it only prints.
            """
    }

    /// An ad-hoc signature is this Mac's alone: Gatekeeper refuses it
    /// elsewhere and TCC identity churns per rebuild. It exists for
    /// packaging tests on the building Mac, so it may never reach the CDN.
    /// A refusal, not a default — a default can be overridden by a flag.
    public func validate() throws {
        if identity == .adHoc, appcast?.publish == true {
            throw ConfigurationError(description: "--ad-hoc cannot publish: an ad-hoc signature is valid on this Mac only, and Gatekeeper refuses it everywhere else")
        }
        if identity == .adHoc, notaryProfile != nil {
            throw ConfigurationError(description: "--ad-hoc cannot notarize: Apple requires a Developer ID signature with the hardened runtime")
        }
    }

    public func steps(fileManager fm: FileManager = .default) -> [Step] {
        var steps: [Step] = []
        // The tools come first because the EdDSA guard needs `generate_keys`.
        // The shell copies fetched them late and made the guard conditional on
        // their presence (`if [ -x ... ]`), so the very first cut on a fresh
        // Mac — the one most likely to have the wrong key — skipped it.
        if appcast != nil {
            steps.append(.fetchToolsIfMissing(bin: toolsBin))
            steps.append(.requireEdDSAKeyMatch(app: app.url, toolsBin: toolsBin))
        }
        steps += Signing.plan(Signing.insideOut(app: app.url, entitlements: entitlements, fileManager: fm),
                              identity: identity).map(Step.run)
        steps.append(.run(Command("rm", "-f", zip.path)))
        if let notaryProfile {
            steps += Notarize.plan(app: app.url, zip: zip, profile: notaryProfile)
        } else {
            steps.append(.run(Notarize.zip(app: app.url, to: zip)))
        }
        if let target = appcast {
            steps += Appcast.generatePlan(feedDir: target.feedDir, currentZip: zip,
                                          prefixURL: target.prefixURL, toolsBin: toolsBin)
            let appcastFile = target.feedDir.appending(path: "appcast.xml")
            steps.append(.requireSingleItem(appcast: appcastFile))
            steps.append(.rewriteToStableKey(appcast: appcastFile, prefixURL: target.prefixURL, appName: app.name))
            if target.publish {
                steps += Appcast.publishPlan(zip: zip, appcast: appcastFile,
                                             prefix: target.cdnPrefix, appName: app.name)
                steps.append(.checkLiveFeed(prefixURL: target.prefixURL))
            }
        }
        return steps
    }
}

/// Runs a plan. Every step announces itself before it acts, so a transcript
/// of a release reads as the plan it came from.
public struct Executor {
    public var runner: Runner
    public var fetcher: Feed.Fetcher
    public var fileManager: FileManager
    public var log: @Sendable (String) -> Void

    public init(runner: Runner = SystemRunner(), fetcher: Feed.Fetcher = Feed.URLSessionFetcher(),
                fileManager: FileManager = .default, log: @escaping @Sendable (String) -> Void) {
        self.runner = runner
        self.fetcher = fetcher
        self.fileManager = fileManager
        self.log = log
    }

    public struct StepFailure: Error, CustomStringConvertible {
        public var description: String
    }

    public func execute(_ steps: [Step]) throws {
        for step in steps { try execute(step) }
    }

    public func execute(_ step: Step) throws {
        log("→ \(step)")
        switch step {
        case .run(let c):
            try runner.run(c)
        case .stream(let c):
            try runner.run(c, streaming: true)

        case .fetchToolsIfMissing(let bin):
            guard !fileManager.isExecutableFile(atPath: bin.appending(path: "generate_appcast").path) else {
                log("  tools present")
                return
            }
            for c in Appcast.fetchToolsPlan(into: bin) {
                log("  → \(c)")
                try runner.run(c, streaming: true)
            }
            guard fileManager.isExecutableFile(atPath: bin.appending(path: "generate_appcast").path) else {
                throw StepFailure(description: "fetched Sparkle \(Appcast.sparkleToolsVersion) but \(bin.path)/generate_appcast is still not there")
            }

        case .requireEdDSAKeyMatch(let app, let toolsBin):
            let bundle = AppBundle(app)
            guard let pinned = try bundle.publicEDKey() else {
                throw StepFailure(description: "no SUPublicEDKey in \(app.lastPathComponent): this is a DEV-lane bundle (make-bundle without the release keys) and it can never accept an update — rebuild it for release before cutting")
            }
            let keychain = try runner.run(Command(toolsBin.appending(path: "generate_keys").path, "-p"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard keychain == pinned else {
                throw StepFailure(description: "SUPublicEDKey mismatch: Keychain \(keychain) vs app \(pinned) — every update signed with the Keychain key would be REJECTED by the shipped app; aborting before the first signature")
            }
            log("  EdDSA key matches: \(pinned)")

        case .requireSingleItem(let appcast):
            let xml = try read(appcast)
            let count = Appcast.itemCount(xml: xml)
            guard count == 1 else {
                throw StepFailure(description: "appcast has \(count) items, expected 1 — every item's enclosure points at the same stable key, so only the newest can be truthful; the others describe bytes that key no longer holds (\(appcast.path))")
            }

        case .rewriteToStableKey(let appcast, let prefixURL, let appName):
            let xml = try read(appcast)
            let rewritten = Appcast.rewriteToStableKey(xml: xml, prefixURL: prefixURL, appName: appName)
            let key = Appcast.stableKey(prefixURL: prefixURL, appName: appName)
            guard rewritten.contains("url=\"\(key)\"") else {
                throw StepFailure(description: "rewrite produced no enclosure at \(key) — the generated feed's url did not match the expected \(prefixURL)\(appName)-vX.Y.Z.zip shape (\(appcast.path))")
            }
            try write(rewritten, to: appcast)
            log("  enclosure → \(key)")

        case .checkLiveFeed(let prefixURL):
            switch try Feed.checkLive(prefixURL: prefixURL, fetcher: fetcher) {
            case .ok(let e):
                log("  live: \(e.url) version \(e.version ?? "?") length \(e.length)")
            case .lengthMismatch(let feed, let live):
                throw StepFailure(description: "LIVE FEED MISMATCH: appcast says length=\(feed), the live zip is \(live) bytes — every installed copy will fail this update; republish both keys")
            case .noEnclosure:
                throw StepFailure(description: "no enclosure in the live \(prefixURL)appcast.xml")
            }
        }
    }

    private func read(_ url: URL) throws -> String {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else {
            throw StepFailure(description: "cannot read \(url.path)")
        }
        return s
    }

    private func write(_ s: String, to url: URL) throws {
        do { try s.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw StepFailure(description: "cannot write \(url.path): \(error.localizedDescription)") }
    }
}
