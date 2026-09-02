import Foundation

/// A built `.app` on disk, read for the facts a release needs. Everything
/// here is read back OFF the bundle rather than passed alongside it: the
/// version that names the zip is the one stamped in the plist, and the
/// EdDSA key the guard checks is the one the shipped app will actually
/// trust.
public struct AppBundle: Sendable {
    public var url: URL

    public init(_ url: URL) { self.url = url }

    /// `Fake.app` → `Fake`. The executable name, the zip stem and the
    /// stable CDN key all derive from this one token.
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public var infoPlistURL: URL { url.appending(path: "Contents/Info.plist") }

    public struct ReadError: Error, CustomStringConvertible {
        public var description: String
    }

    public func infoPlist() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: infoPlistURL) else {
            throw ReadError(description: "no Info.plist at \(infoPlistURL.path)")
        }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ReadError(description: "\(infoPlistURL.path) is not a plist dictionary")
        }
        return plist
    }

    public func string(_ key: String) throws -> String? { try infoPlist()[key] as? String }

    /// `CFBundleShortVersionString` — what names the zip and the GitHub tag.
    public func marketingVersion() throws -> String {
        guard let v = try string("CFBundleShortVersionString") else {
            throw ReadError(description: "no CFBundleShortVersionString in \(infoPlistURL.path)")
        }
        return v
    }

    /// The EdDSA public key the app pins. Absent means the bundle is a
    /// DEV-lane cut (`make-bundle` without `--release`): it has no SUFeedURL,
    /// so it never self-updates, and releasing it to a feed would ship an app
    /// that cannot accept the next update.
    public func publicEDKey() throws -> String? { try string("SUPublicEDKey") }

    /// Every Mach-O in the bundle: the executables and the embedded binaries
    /// inside frameworks, plug-ins and XPC services. A universal release must
    /// be proven across ALL of them — disk's widget is built by a separate
    /// toolchain and can be thin while the app is fat.
    public func machOFiles(fileManager fm: FileManager = .default) -> [URL] {
        var found: [URL] = []
        guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
                                       options: [.skipsHiddenFiles]) else { return found }
        for case let file as URL in walk {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            guard values?.isRegularFile == true, values?.isExecutable == true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { continue }
            // Mach-O 64-bit (cf/ce faedfe) and the fat/universal wrappers.
            let bytes = [UInt8](magic)
            let isMachO = bytes == [0xcf, 0xfa, 0xed, 0xfe] || bytes == [0xce, 0xfa, 0xed, 0xfe]
                || bytes == [0xca, 0xfe, 0xba, 0xbe] || bytes == [0xbe, 0xba, 0xfe, 0xca]
            if isMachO { found.append(file) }
        }
        return found.sorted { $0.path < $1.path }
    }
}
