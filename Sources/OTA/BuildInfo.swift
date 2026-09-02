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
    /// A peer old enough to predate this field sends no name, so the READER
    /// supplies it — it ran the command, so it is what knows. Decode through
    /// `decode(_:naming:)` or a `JSONDecoder.naming(_:)`, never a bare
    /// `JSONDecoder()`, or a remote row renders an empty name and nothing
    /// says why.
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

    /// The name a decode falls back to when the peer sent none. Set it
    /// through `decode(_:naming:)` or `JSONDecoder.naming(_:)`.
    public static let nameUserInfoKey = CodingUserInfoKey(rawValue: "com.ramonfabrega.ota.buildInfo.name")!

    /// An older peer's `<app> version --json` has neither `dev` nor `name`:
    /// that build predates the lane split, and it was always a release cut.
    /// Decoding must not fail over a field that did not exist yet — the
    /// whole point of asking a remote host its version is to survive skew.
    /// A peer new enough to send its own `name` always wins over the
    /// reader's fallback.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = decoder.userInfo[Self.nameUserInfoKey] as? String ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? fallback
        version = try c.decodeIfPresent(String.self, forKey: .version)
        build = try c.decodeIfPresent(Int.self, forKey: .build)
        bundlePath = try c.decodeIfPresent(String.self, forKey: .bundlePath)
        executablePath = try c.decode(String.self, forKey: .executablePath)
        dev = try c.decodeIfPresent(Bool.self, forKey: .dev) ?? false
    }

    /// Decode a peer's `<app> version --json`. `naming` is what the reader
    /// calls the command it ran, used only when the peer is too old to say.
    public static func decode(_ data: Data, naming name: String) throws -> BuildInfo {
        try JSONDecoder.naming(name).decode(BuildInfo.self, from: data)
    }

    /// A copy that knows what it is called — for a `BuildInfo` that arrived
    /// some way other than a decode. Never overwrites a name already set.
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

extension JSONDecoder {
    /// A decoder that names any `BuildInfo` it reads whose peer was too old
    /// to name itself. Use it for a nested decode too — a `BuildInfo` inside
    /// some larger status payload gets the fallback the same way.
    public static func naming(_ name: String) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[BuildInfo.nameUserInfoKey] = name
        return decoder
    }
}
