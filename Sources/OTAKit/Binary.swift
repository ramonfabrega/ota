import Foundation

/// Facts read off a built Mach-O, never typed twice. Each has a pure parser
/// over the tool's text (tests pin the format) and a live reader.
public enum Binary {
    public struct ReadError: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: minos

    /// The deployment target the binary was BUILT for, from `LC_BUILD_VERSION`.
    /// This is what `LSMinimumSystemVersion` must say: ccc v0.1.3 shipped a
    /// plist saying 14.0 over a binary built for 26 and Sparkle on the
    /// receiving Mac refused the update with "requires macOS 26.0 or later".
    public static func minos(fromLoadCommands text: String) -> String? {
        var inBuildVersion = false
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("cmd ") { inBuildVersion = t == "cmd LC_BUILD_VERSION" }
            guard inBuildVersion, t.hasPrefix("minos ") else { continue }
            return String(t.dropFirst("minos ".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func minos(of binary: URL, runner: Runner = SystemRunner()) throws -> String {
        let text = try runner.run(Command("otool", "-l", binary.path))
        guard let v = minos(fromLoadCommands: text) else {
            throw ReadError(description: "no LC_BUILD_VERSION minos in \(binary.path)")
        }
        return v
    }

    // MARK: linked frameworks

    /// The frameworks the binary actually loads (`@rpath/...framework` and
    /// `@executable_path/...framework` in `otool -L`). Two policies share
    /// this one fact: everything linked MUST be embedded (ccc asserts
    /// Sparkle is there), and nothing else NEED be (mux prunes the rest —
    /// Xcode embeds 51 KB linker stubs of frameworks the binary never loads).
    public static func linkedFrameworks(fromOtoolL text: String) -> [String] {
        var names: [String] = []
        for line in text.split(separator: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("@rpath/") || t.hasPrefix("@executable_path/") else { continue }
            let path = t.split(separator: " ", maxSplits: 1).first.map(String.init) ?? t
            guard let range = path.range(of: ".framework/") else { continue }
            let name = path[..<range.lowerBound].split(separator: "/").last.map { $0 + ".framework" }
            if let name, !names.contains(String(name)) { names.append(String(name)) }
        }
        return names
    }

    public static func linkedFrameworks(of binary: URL, runner: Runner = SystemRunner()) throws -> [String] {
        linkedFrameworks(fromOtoolL: try runner.run(Command("otool", "-L", binary.path)))
    }

    // MARK: archs

    /// `lipo -archs` → `["arm64", "x86_64"]`. A universal release must be
    /// PROVEN: SwiftPM's multi-arch build emits to a different products dir
    /// and a bundle script that reads `.build/release` ships thin silently.
    public static func archs(fromLipo text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func archs(of binary: URL, runner: Runner = SystemRunner()) throws -> [String] {
        archs(fromLipo: try runner.run(Command("lipo", "-archs", binary.path)))
    }
}
