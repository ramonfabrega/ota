import Foundation

/// `<command>` on PATH as a symlink INTO the installed bundle (VS Code's
/// pattern), so the command and the app are always the same build and a
/// Sparkle update — which replaces the bundle at the same path — carries the
/// link along (proven on ccc v0.1.x). Offered by the app on first launch
/// when no command is found; `<app> install-cli` is its twin.
public struct CLIInstall: Sendable {
    /// `ccc`, `scry` — the name on PATH.
    public var command: String
    /// The first that exists and is writable wins; the last is created if
    /// none is — `~/.local/bin` is where `claude`'s own installer puts
    /// things, so it is on PATH on any Mac that runs the harness.
    public var directories: [String]
    public var home: String

    public static let defaultDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]

    public init(command: String, directories: [String] = defaultDirectories,
                home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.command = command
        self.directories = directories
        self.home = home
    }

    public enum Status: Equatable, Sendable {
        /// A link that resolves to this executable.
        case installed(path: String)
        /// A symlink whose target is gone — an app that moved or was deleted. Ours to relink.
        case dangling(path: String, target: String)
        /// Something else: another bundle's link, a dev build, a real file. The user's; never replaced quietly.
        case foreign(path: String, target: String?)
        case missing

        public var path: String? {
            switch self {
            case .installed(let p), .dangling(let p, _), .foreign(let p, _): p
            case .missing: nil
            }
        }
    }

    func expand(_ dir: String) -> String {
        dir.hasPrefix("~/") ? home + dir.dropFirst(1) : dir
    }

    /// The first `command` found in `directories` (then every PATH entry),
    /// judged against `executable`.
    public func status(executable: String = BuildInfo.currentExecutablePath,
                       path: String? = ProcessInfo.processInfo.environment["PATH"]) -> Status {
        let fm = FileManager.default
        let dirs = directories + (path ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        for dir in dirs.map(expand) where seen.insert(dir).inserted {
            let link = dir + "/" + command
            guard fm.fileExists(atPath: link) || (try? fm.destinationOfSymbolicLink(atPath: link)) != nil else { continue }
            let target = try? fm.destinationOfSymbolicLink(atPath: link)
            let resolved = URL(filePath: link).resolvingSymlinksInPath().path
            if resolved == URL(filePath: executable).resolvingSymlinksInPath().path { return .installed(path: link) }
            if let target, !fm.fileExists(atPath: resolved) { return .dangling(path: link, target: target) }
            return .foreign(path: link, target: target)
        }
        return .missing
    }

    public struct Result: Equatable, Sendable {
        public var command: String
        public var path: String
        public var replaced: String?
        /// The directory had to be created; it may not be on PATH yet.
        public var createdDirectory: Bool

        public var description: String {
            var out = "\(command) → \(path)"
            if let replaced { out += " (was \(replaced))" }
            if createdDirectory {
                out += "; created \(URL(filePath: path).deletingLastPathComponent().path) — add it to PATH if it is not"
            }
            return out
        }
    }

    public struct InstallError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Link `command` to `executable`. A symlink already there is relinked
    /// (its old target reported); a regular file is refused unless `force`.
    @discardableResult
    public func install(executable: String = BuildInfo.currentExecutablePath,
                        directory: String? = nil, force: Bool = false) throws -> Result {
        let fm = FileManager.default
        var created = false
        let dir: String
        if let directory {
            dir = expand(directory)
            guard fm.fileExists(atPath: dir) else { throw InstallError(description: "\(dir) does not exist") }
        } else {
            let expanded = directories.map(expand)
            if let writable = expanded.first(where: { fm.isWritableFile(atPath: $0) && (try? fm.contentsOfDirectory(atPath: $0)) != nil }) {
                dir = writable
            } else if let last = expanded.last {
                try fm.createDirectory(atPath: last, withIntermediateDirectories: true)
                dir = last
                created = true
            } else {
                throw InstallError(description: "no directory to install into")
            }
        }
        let link = dir + "/" + command
        var replaced: String?
        if let target = try? fm.destinationOfSymbolicLink(atPath: link) {
            // Already ours and already right: reinstalling is a no-op, and
            // reporting a "replaced" target it never replaced would read as
            // churn in an install that did nothing.
            if target == executable { return Result(command: command, path: link, replaced: nil, createdDirectory: created) }
            replaced = target
            try fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            guard force else { throw InstallError(description: "\(link) exists and is not a symlink; pass force to replace it") }
            replaced = link
            try fm.removeItem(atPath: link)
        }
        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: executable)
        } catch {
            throw InstallError(description: "could not link \(link): \(error.localizedDescription)")
        }
        return Result(command: command, path: link, replaced: replaced, createdDirectory: created)
    }
}
