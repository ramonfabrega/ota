import Foundation

/// The fleet's versioning: the marketing version is the `VERSION` file at
/// the repo root (one place to bump), and the build number is the git
/// commit count — monotonic with zero upkeep, and what Sparkle compares,
/// so a dev build (commits past the tag) always outranks the released zip
/// and is never offered a downgrade.
public struct Version: Equatable, Sendable, CustomStringConvertible {
    public var marketing: String
    public var build: Int

    public init(marketing: String, build: Int) {
        self.marketing = marketing
        self.build = build
    }

    public var description: String { "\(marketing) (\(build))" }

    public struct ReadError: Error, CustomStringConvertible {
        public var description: String
    }

    /// `VERSION` + `git rev-list --count HEAD` in `repo`.
    public static func read(repo: URL, runner: Runner = SystemRunner()) throws -> Version {
        let file = repo.appending(path: "VERSION")
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
            throw ReadError(description: "no VERSION file at \(file.path)")
        }
        let marketing = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSemver(marketing) else {
            throw ReadError(description: "VERSION is \"\(marketing)\", expected MAJOR.MINOR.PATCH")
        }
        let count = try runner.run(Command("git", "-C", repo.path, "rev-list", "--count", "HEAD"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let build = Int(count) else {
            throw ReadError(description: "git rev-list --count HEAD said \"\(count)\"")
        }
        return Version(marketing: marketing, build: build)
    }

    static func isSemver(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
