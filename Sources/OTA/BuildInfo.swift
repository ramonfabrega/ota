import Foundation

/// Which build this is. Version and build come from the bundle's Info.plist
/// (`VERSION`, and the git commit count), so the answer is the same one
/// Sparkle compares — and skew between two Macs, or between the command on
/// PATH and the app holding a socket, is a number rather than a "malformed
/// request". A bare `.build/debug/<app>` has no plist and says so.
public struct BuildInfo: Codable, Sendable, Equatable {
    public var version: String?
    public var build: Int?
    /// The `.app` this executable lives in, when it does.
    public var bundlePath: String?
    /// The executable itself, symlinks resolved — what `CLIInstall` links to.
    public var executablePath: String
    /// The dev lane: a bundle with no Sparkle feed, or no bundle at all. One
    /// definition — `Updater` keys on the same absence.
    public var dev: Bool

    public var isBundled: Bool { bundlePath != nil && version != nil }

    /// `0.1.4 (53)`, `0.1.4 (56) dev`, or `dev` for a bare binary.
    public var short: String {
        guard let version else { return "dev" }
        return (build.map { "\(version) (\($0))" } ?? version) + (dev ? " dev" : "")
    }

    /// This process. The executable is resolved through its symlinks first
    /// — the command on PATH IS a symlink into the bundle — and the bundle is
    /// the nearest `.app` above it, read directly rather than trusted to
    /// `Bundle.main`, which a symlinked CLI launch can confuse.
    public static let current: BuildInfo = {
        let executable = (Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        return BuildInfo(executable: executable)
    }()

    public init(executable: URL) {
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
