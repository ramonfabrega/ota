import Foundation

/// Which build this is. Version and build come from the bundle's Info.plist
/// (`VERSION`, and the git commit count), so the answer is the same one
/// Sparkle compares — and skew between two Macs, or between the command on
/// PATH and the app holding a socket, is a number rather than a "malformed
/// request". A bare `.build/debug/<app>` has no plist and says so.
///
/// Zero dependencies on purpose. A consumer's CLI-side library wants this
/// and `CLIInstall` without linking Sparkle behind them — ccc's `CCCKit` is
/// what every test links, and a signed binary framework has no business
/// there. Sparkle lives in `OTAUpdater`, which only the executable target
/// that carries the Frameworks rpath imports.
public struct BuildInfo: Codable, Sendable, Equatable {
    /// `ccc`, `Disk` — what this build calls itself. Everything user-facing
    /// derives from it, so a consumer names itself once.
    ///
    /// Empty when decoded from a peer old enough to predate this field; see
    /// `naming(_:)`, which is how a reader that knows the answer fills it in.
    public var name: String
    public var version: String?
    public var build: Int?
    /// The `.app` this executable lives in, when it does.
    public var bundlePath: String?
    /// The executable itself, symlinks resolved — what `CLIInstall` links to.
    public var executablePath: String
    /// The dev lane: a bundle with no Sparkle feed, or no bundle at all. One
    /// definition — `Updater` keys on the same absence, so "which lane is
    /// this" can never be answered two different ways.
    public var dev: Bool

    public init(name: String, version: String?, build: Int?, bundlePath: String?,
                executablePath: String, dev: Bool = false) {
        self.name = name
        self.version = version
        self.build = build
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.dev = dev
    }

    /// An older peer's `<app> version --json` has neither `dev` nor `name`:
    /// that build predates the lane split, and it was always a release cut.
    /// Decoding must not fail over a field that did not exist yet — the
    /// whole point of asking a remote host its version is to survive skew.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version)
        build = try c.decodeIfPresent(Int.self, forKey: .build)
        bundlePath = try c.decodeIfPresent(String.self, forKey: .bundlePath)
        executablePath = try c.decode(String.self, forKey: .executablePath)
        dev = try c.decodeIfPresent(Bool.self, forKey: .dev) ?? false
    }

    /// A copy that knows what it is called. For a `BuildInfo` decoded from a
    /// peer that predates `name`: the reader ran the command, so the reader
    /// is the one that knows.
    public func naming(_ name: String) -> BuildInfo {
        var copy = self
        if copy.name.isEmpty { copy.name = name }
        return copy
    }

    public var isBundled: Bool { bundlePath != nil && version != nil }

    /// `0.1.4 (53)`, `0.1.4 (56) dev`, or `dev` for a bare binary.
    public var short: String {
        guard let version else { return "dev" }
        return (build.map { "\(version) (\($0))" } ?? version) + (dev ? " dev" : "")
    }

    /// What a status item or window title is called: `ccc`, or `ccc·dev` on
    /// the dev lane, so a glance says which build is in front of you.
    public var appTitle: String { dev ? "\(name)·dev" : name }

    /// The `<app> version` line.
    public var description: String {
        isBundled ? "\(name) \(short)  \(bundlePath ?? "")"
                  : "\(name) dev build (not a bundle: \(executablePath))"
    }

    /// This process's executable, resolved through its symlinks — the command
    /// on PATH IS a symlink into the bundle, and `Bundle.main` can be
    /// confused by a launch through one.
    public static let currentExecutable: URL = (Bundle.main.executableURL
        ?? URL(filePath: CommandLine.arguments[0])).resolvingSymlinksInPath()

    public static var currentExecutablePath: String { currentExecutable.path }

    /// This process. The bundle is the nearest `.app` above the resolved
    /// executable, read directly rather than trusted to `Bundle.main`.
    public static func current(name: String) -> BuildInfo {
        BuildInfo(name: name, executable: currentExecutable)
    }

    public init(name: String, executable: URL) {
        self.name = name
        executablePath = executable.path
        dev = true
        var dir = executable.deletingLastPathComponent()
        while dir.path != "/" {
            if dir.pathExtension == "app",
               let bundle = Bundle(url: dir),
               let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                self.version = version
                self.build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
                self.bundlePath = dir.path
                self.dev = bundle.object(forInfoDictionaryKey: "SUFeedURL") == nil
                return
            }
            dir = dir.deletingLastPathComponent()
        }
    }
}
