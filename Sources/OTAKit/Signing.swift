import Foundation

/// Developer ID signing, the inside-out order, as a plan.
public enum Signing {
    /// A `Developer ID Application: …` identity from
    /// `security find-identity -v -p codesigning`. The first one wins; the
    /// fleet has one.
    public static func developerID(fromFindIdentity text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let open = line.range(of: "\"Developer ID Application: ") else { continue }
            let rest = line[open.lowerBound...].dropFirst()
            guard let close = rest.firstIndex(of: "\"") else { continue }
            return String(rest[..<close])
        }
        return nil
    }

    public static func developerID(runner: Runner = SystemRunner()) throws -> String? {
        developerID(fromFindIdentity: try runner.run(Command("security", "find-identity", "-v", "-p", "codesigning")))
    }

    public enum Identity: Equatable, Sendable {
        /// Hardened runtime + secure timestamp: what notarization requires.
        case developerID(String)
        /// `codesign --sign -`. The dev lane and packaging tests; never
        /// shipped across machines (Gatekeeper refuses it, and TCC identity
        /// churns per rebuild).
        case adHoc

        var arguments: [String] {
            switch self {
            case .developerID(let id): ["--force", "--timestamp", "--options", "runtime", "--sign", id]
            case .adHoc: ["--force", "--sign", "-"]
            }
        }
    }

    /// One thing to sign, in order.
    public struct Step: Equatable, Sendable {
        public var path: String
        /// A nested bundle re-signed with `--preserve-metadata=entitlements`
        /// keeps its own (Sparkle's Downloader XPC needs its sandbox; disk's
        /// widget appex needs app-sandbox or notarization rejects it).
        public var preserveEntitlements: Bool
        /// An entitlements file for the app itself (mux).
        public var entitlements: String?
    }

    /// The order codesign needs: deepest first, the app last. Hardened
    /// runtime's library validation demands every dylib carry OUR team id,
    /// which is why Sparkle — shipped signed by its authors — is re-signed
    /// at all. Sparkle's nested executables come first per its docs, then
    /// every framework, plug-in and XPC service, then every helper, then the
    /// app.
    ///
    /// A helper is nested code outside those bundle directories: everything
    /// in `Contents/Helpers` (Apple's place for helper tools and apps), and
    /// any Mach-O in `Contents/MacOS` other than the main executable.
    /// garita's agent (`Contents/Helpers/garita`, a second Rust binary) is
    /// the first. Left unsigned it carries only the linker's ad-hoc
    /// signature, which notarization rejects as nested code without the
    /// hardened runtime — so garita signed it by hand, a second copy of the
    /// identity lookup and the flags. Symlinks are skipped (not code; the
    /// target is signed where it lives). Helpers keep their entitlements, as
    /// plug-ins do: a bare binary has none to keep, a helper app may.
    public static func insideOut(app: URL, entitlements: String? = nil,
                                 fileManager fm: FileManager = .default) -> [Step] {
        var steps: [Step] = []
        let contents = app.appending(path: "Contents")
        let sparkle = contents.appending(path: "Frameworks/Sparkle.framework/Versions/B")
        if fm.fileExists(atPath: sparkle.path) {
            steps.append(Step(path: sparkle.appending(path: "XPCServices/Installer.xpc").path, preserveEntitlements: false))
            steps.append(Step(path: sparkle.appending(path: "XPCServices/Downloader.xpc").path, preserveEntitlements: true))
            steps.append(Step(path: sparkle.appending(path: "Autoupdate").path, preserveEntitlements: false))
            steps.append(Step(path: sparkle.appending(path: "Updater.app").path, preserveEntitlements: false))
        }
        for dir in ["Frameworks", "PlugIns", "XPCServices"] {
            let url = contents.appending(path: dir)
            let entries = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
            for entry in entries where !entry.hasPrefix(".") {
                steps.append(Step(path: url.appending(path: entry).path, preserveEntitlements: dir != "Frameworks"))
            }
        }
        for helper in helpers(app: app, fileManager: fm) {
            steps.append(Step(path: helper.path, preserveEntitlements: true))
        }
        steps.append(Step(path: app.path, preserveEntitlements: false, entitlements: entitlements))
        return steps
    }

    /// The helpers in `app`, in signing order: every non-hidden entry of
    /// `Contents/Helpers` that is a bundle or a Mach-O, then every Mach-O in
    /// `Contents/MacOS` besides `CFBundleExecutable`.
    public static func helpers(app: URL, fileManager fm: FileManager = .default) -> [URL] {
        let contents = app.appending(path: "Contents")
        func entries(_ dir: String) -> [URL] {
            let url = contents.appending(path: dir)
            return ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
                .filter { !$0.hasPrefix(".") }
                .map { url.appending(path: $0) }
                .filter { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) == nil }
        }
        var found: [URL] = []
        for entry in entries("Helpers") {
            var isDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: entry.path, isDirectory: &isDirectory)
            if isDirectory.boolValue || AppBundle.isMachO(entry) { found.append(entry) }
        }
        let main = AppBundle(app).mainExecutableName()
        for entry in entries("MacOS") where entry.lastPathComponent != main && AppBundle.isMachO(entry) {
            found.append(entry)
        }
        return found
    }

    /// The `codesign` commands for `steps`, plus the strict verify at the end.
    public static func plan(_ steps: [Step], identity: Identity) -> [Command] {
        var commands = steps.map { step -> Command in
            var args = identity.arguments
            if step.preserveEntitlements { args.append("--preserve-metadata=entitlements") }
            if let e = step.entitlements { args += ["--entitlements", e] }
            return Command("codesign", args + [step.path])
        }
        if let app = steps.last?.path {
            commands.append(Command("codesign", "--verify", "--deep", "--strict", "--verbose=2", app))
        }
        return commands
    }
}
