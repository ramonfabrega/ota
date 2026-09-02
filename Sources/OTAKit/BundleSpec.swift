import Foundation

/// What a SwiftPM app's `.app` needs beyond its binary. Five per-app facts;
/// everything else (versioning, minos, the Sparkle keys' shape) is fleet.
/// Xcode-built apps (mux) never see this — Xcode assembles their bundle.
public struct BundleSpec: Equatable, Sendable {
    /// `ccc` — the `.app` name and the executable name inside it.
    public var name: String
    /// `Claude Code Command` — `CFBundleDisplayName`; defaults to `name`.
    public var displayName: String
    /// `com.ramonfabrega.ccc`.
    public var bundleID: String
    public var version: Version
    /// From the binary (`Binary.minos`), never typed.
    public var minimumSystemVersion: String
    /// Self-update. `nil` is the dev lane: no SUFeedURL means the app-side
    /// `Updater` never constructs Sparkle — a bare binary with Sparkle
    /// started puts up a MODAL alert and blocks the main thread.
    public var feed: Feed?
    /// `Contents/Resources/<name>.icns`, when there is one.
    public var iconFile: String?
    /// Extra keys, verbatim (`LSUIElement`, `NSHumanReadableCopyright`, …).
    public var extra: [String: String]

    public struct Feed: Equatable, Sendable {
        public var url: String
        /// The fleet's EdDSA PUBLIC key; the private half lives in one
        /// Keychain. `ota release` refuses to cut if the Keychain's key does
        /// not match this.
        public var publicEDKey: String
        public var automaticChecks: Bool

        public init(url: String, publicEDKey: String, automaticChecks: Bool = true) {
            self.url = url
            self.publicEDKey = publicEDKey
            self.automaticChecks = automaticChecks
        }
    }

    public init(name: String, displayName: String? = nil, bundleID: String, version: Version,
                minimumSystemVersion: String, feed: Feed? = nil, iconFile: String? = nil,
                extra: [String: String] = [:]) {
        self.name = name
        self.displayName = displayName ?? name
        self.bundleID = bundleID
        self.version = version
        self.minimumSystemVersion = minimumSystemVersion
        self.feed = feed
        self.iconFile = iconFile
        self.extra = extra
    }

    /// The `Info.plist` dictionary. Order-independent; `infoPlistXML` serializes it.
    public var infoPlist: [String: Any] {
        var d: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": name,
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": version.marketing,
            "CFBundleVersion": String(version.build),
            "LSMinimumSystemVersion": minimumSystemVersion,
            "NSHighResolutionCapable": true,
        ]
        if let iconFile { d["CFBundleIconFile"] = iconFile }
        if let feed {
            d["SUFeedURL"] = feed.url
            d["SUPublicEDKey"] = feed.publicEDKey
            d["SUEnableAutomaticChecks"] = feed.automaticChecks
        }
        for (k, v) in extra { d[k] = v }
        return d
    }

    public func infoPlistXML() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
    }
}
