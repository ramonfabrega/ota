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
    /// Runs `command` and returns stdout; throws `CommandFailure` on non-zero
    /// exit. `streaming` hands the child our own stdout/stderr instead of
    /// capturing it: `notarytool submit --wait` and `generate_appcast` run for
    /// minutes and say useful things while they do, and a release that prints
    /// nothing through four of them reads as a hang. Streaming returns "".
    @discardableResult
    func run(_ command: Command, streaming: Bool) throws -> String
}

extension Runner {
    @discardableResult
    public func run(_ command: Command) throws -> String { try run(command, streaming: false) }
}

public struct SystemRunner: Runner {
    public init() {}

    @discardableResult
    public func run(_ command: Command, streaming: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command.program] + command.arguments

        if streaming {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CommandFailure(command: command, status: process.terminationStatus, stderr: "")
            }
            return ""
        }

        // Both pipes are drained CONCURRENTLY, and only then is the child
        // reaped. Draining one to EOF first deadlocks the moment the other
        // fills its 64K kernel buffer — which is exactly what a chatty child
        // does, so the bug waits for the noisiest, longest command to hit it.
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        nonisolated(unsafe) var stdout = Data()
        nonisolated(unsafe) var stderr = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { stdout = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { stderr = err.fileHandleForReading.readDataToEndOfFile() }
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(command: command, status: process.terminationStatus,
                                 stderr: String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}
