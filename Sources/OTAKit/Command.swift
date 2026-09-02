import Foundation

/// One process invocation. Every step of a release is a `Command` first and
/// a side effect second: plans are values, so a test can read the exact
/// `codesign` sequence and `ota release --dry-run` can print it.
public struct Command: Equatable, Sendable, CustomStringConvertible {
    public var program: String
    public var arguments: [String]

    public init(_ program: String, _ arguments: [String]) {
        self.program = program
        self.arguments = arguments
    }

    public init(_ program: String, _ arguments: String...) {
        self.init(program, arguments)
    }

    /// Shell-quoted, for humans and dry runs.
    public var description: String {
        ([program] + arguments).map { arg in
            arg.rangeOfCharacter(from: .whitespaces) == nil && !arg.contains("\"") ? arg : "\"" + arg.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }
}

public struct CommandFailure: Error, CustomStringConvertible {
    public var command: Command
    public var status: Int32
    public var stderr: String
    public var description: String { "\(command) → exit \(status)\(stderr.isEmpty ? "" : ": " + stderr)" }
}

/// Runs commands. `SystemRunner` is the real one; tests substitute a
/// recorder or canned output.
public protocol Runner: Sendable {
    /// Runs `command`, returns stdout; throws `CommandFailure` on non-zero exit.
    @discardableResult
    func run(_ command: Command) throws -> String
}

public struct SystemRunner: Runner {
    public init() {}

    @discardableResult
    public func run(_ command: Command) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command.program] + command.arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(command: command, status: process.terminationStatus, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }
}
