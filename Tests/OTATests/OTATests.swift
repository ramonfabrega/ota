import Foundation
import Testing
@testable import OTA

// This target links OTA and NOT Sparkle. That it builds at all is the check
// on the product split: OTA is what a consumer's CLI-side library imports
// (ccc's CCCKit, which every one of its tests links), and a signed binary
// framework has no business behind two structs that never touch it.

@Suite struct BuildIdentity {
    func fakeApp(feed: Bool, version: String = "0.1.4", build: String = "53") throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "ota-\(UUID().uuidString)")
        let app = dir.appending(path: "ccc.app")
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleExecutable": "ccc",
            "CFBundleIdentifier": "com.example.ccc",
        ]
        if feed { plist["SUFeedURL"] = "https://cdn.example.com/ccc/appcast.xml" }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let executable = app.appending(path: "Contents/MacOS/ccc")
        fm.createFile(atPath: executable.path, contents: Data())
        return executable
    }

    /// The lane is the presence or absence of the feed keys, read off the
    /// bundle — never a flag that could disagree with the plist Sparkle reads.
    @Test func laneIsTheAbsenceOfTheFeed() throws {
        let release = BuildInfo(name: "ccc", executable: try fakeApp(feed: true))
        #expect(!release.dev)
        #expect(release.version == "0.1.4")
        #expect(release.build == 53)
        #expect(release.short == "0.1.4 (53)")
        #expect(release.appTitle == "ccc")
        #expect(release.isBundled)

        let dev = BuildInfo(name: "ccc", executable: try fakeApp(feed: false))
        #expect(dev.dev)
        #expect(dev.short == "0.1.4 (53) dev")
        #expect(dev.appTitle == "ccc·dev")
    }

    /// A bare `.build/debug/ccc` has no plist above it and must say so
    /// rather than look like a release.
    @Test func bareBinaryIsTheDevLane() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bare = dir.appending(path: "ccc")
        FileManager.default.createFile(atPath: bare.path, contents: Data())
        let info = BuildInfo(name: "ccc", executable: bare)
        #expect(info.dev)
        #expect(!info.isBundled)
        #expect(info.short == "dev")
        #expect(info.description.hasPrefix("ccc dev build (not a bundle:"))
    }

    /// The whole point of asking a remote host its version is to survive
    /// skew, so a peer that predates `dev` and `name` must still decode. An
    /// older build predates the lane split and was always a release cut.
    @Test func olderPeerJSONStillDecodes() throws {
        let legacy = Data("""
        {"version":"0.1.2","build":41,"bundlePath":"/Applications/ccc.app","executablePath":"/Applications/ccc.app/Contents/MacOS/ccc"}
        """.utf8)
        // The reader ran the command, so the reader is what supplies the
        // name — and it does so AT the decode, not as a call it could forget.
        let info = try BuildInfo.decode(legacy, naming: "ccc")
        #expect(!info.dev)
        #expect(info.name == "ccc")
        #expect(info.short == "0.1.2 (41)")
        #expect(info.appTitle == "ccc")

        // A peer new enough to name itself always wins over the fallback.
        let newer = Data("""
        {"name":"scry","version":"0.2.0","build":9,"executablePath":"/x/scry","dev":false}
        """.utf8)
        #expect(try BuildInfo.decode(newer, naming: "ccc").name == "scry")

        // The fallback reaches a nested decode too, which is the shape a
        // status payload carrying a BuildInfo actually has.
        struct HostStatus: Decodable { var host: String; var build: BuildInfo }
        let nested = Data("""
        {"host":"air","build":{"version":"0.1.2","build":41,"executablePath":"/x/ccc"}}
        """.utf8)
        #expect(try JSONDecoder.naming("ccc").decode(HostStatus.self, from: nested).build.name == "ccc")

        // A bare decoder still does not throw — skew must never be fatal —
        // but it cannot know the name, which is why the API above exists.
        #expect(try JSONDecoder().decode(BuildInfo.self, from: legacy).name.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let info = BuildInfo(name: "Disk", version: "0.6.0", build: 124,
                             bundlePath: "/Applications/Disk.app",
                             executablePath: "/Applications/Disk.app/Contents/MacOS/Disk")
        let back = try JSONDecoder().decode(BuildInfo.self, from: try JSONEncoder().encode(info))
        #expect(back == info)
        #expect(back.name == "Disk")
    }
}

@Suite struct CommandLink {
    /// A sandbox with its own `home`, so nothing here can see or touch the
    /// real /opt/homebrew/bin or ~/.local/bin.
    func sandbox() throws -> (home: String, bin: String, executable: String) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "ota-\(UUID().uuidString)")
        let bin = home.appending(path: "bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = home.appending(path: "ccc.app/Contents/MacOS/ccc")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: executable.path, contents: Data())
        return (home.path, bin.path, executable.path)
    }

    func installer(_ s: (home: String, bin: String, executable: String)) -> CLIInstall {
        CLIInstall(command: "ccc", directories: [s.bin], home: s.home)
    }

    @Test func linksAndReportsWhatItReplaced() throws {
        let s = try sandbox()
        let cli = installer(s)
        #expect(cli.status(executable: s.executable, path: "") == .missing)

        let first = try cli.install(executable: s.executable)
        #expect(first.path == s.bin + "/ccc")
        #expect(first.replaced == nil)
        #expect(first.description == "ccc → \(s.bin)/ccc")
        #expect(cli.status(executable: s.executable, path: "") == .installed(path: s.bin + "/ccc"))

        // Reinstalling the same target is a no-op and must not report churn.
        #expect(try cli.install(executable: s.executable).replaced == nil)

        // A different bundle's link is ours to relink, and it says what went.
        let other = s.home + "/other.app/Contents/MacOS/ccc"
        try FileManager.default.createDirectory(atPath: URL(filePath: other).deletingLastPathComponent().path,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: other, contents: Data())
        let relinked = try cli.install(executable: other)
        #expect(relinked.replaced == s.executable)
    }

    /// A real file named `ccc` is the user's, not ours: reported, never
    /// replaced quietly.
    @Test func aRealFileIsRefusedWithoutForce() throws {
        let s = try sandbox()
        let cli = installer(s)
        FileManager.default.createFile(atPath: s.bin + "/ccc", contents: Data("#!/bin/sh\n".utf8))
        #expect(cli.status(executable: s.executable, path: "") == .foreign(path: s.bin + "/ccc", target: nil))
        #expect(throws: CLIInstall.InstallError.self) { try cli.install(executable: s.executable) }
        #expect(try cli.install(executable: s.executable, force: true).replaced == s.bin + "/ccc")
    }

    /// An app that moved or was deleted leaves a link pointing at nothing.
    /// That one is ours to fix, unlike a foreign link.
    @Test func aDeadLinkIsDangling() throws {
        let s = try sandbox()
        let cli = installer(s)
        try FileManager.default.createSymbolicLink(atPath: s.bin + "/ccc", withDestinationPath: s.home + "/gone.app/Contents/MacOS/ccc")
        guard case .dangling(let path, let target) = cli.status(executable: s.executable, path: "") else {
            Issue.record("expected dangling, got \(cli.status(executable: s.executable, path: ""))")
            return
        }
        #expect(path == s.bin + "/ccc")
        #expect(target.hasSuffix("gone.app/Contents/MacOS/ccc"))
    }

    @Test func createsTheLastDirectoryWhenNoneExists() throws {
        let s = try sandbox()
        let cli = CLIInstall(command: "ccc", directories: ["/nonexistent-ota-test", "~/.local/bin"], home: s.home)
        let result = try cli.install(executable: s.executable)
        #expect(result.createdDirectory)
        #expect(result.path == s.home + "/.local/bin/ccc")
        #expect(result.description.contains("add it to PATH"))
    }
}
