import Foundation

/// Assembles a SwiftPM app's `.app` from its build products. The toolbox
/// upstream of a built bundle — never the build itself, which is the only
/// genuinely per-app part (mux is xcodegen, disk is universal plus an
/// xcodebuilt widget, ccc is one `swift build`).
///
/// SIGNING IS THE CALLER'S JOB. The dev lane signs ad-hoc for a stable TCC
/// identity; `ota release` signs with Developer ID and notarizes.
public enum Bundler {
    public struct Error: Swift.Error, CustomStringConvertible {
        public var description: String
    }

    /// SwiftPM's multi-arch build emits LIPO'd products to a DIFFERENT
    /// directory; `.build/release` stays a symlink to the host-arch build,
    /// so a bundler that reads it ships an arm64-only "universal" release
    /// and says nothing.
    public static func productsDirectory(repo: URL, universal: Bool) -> URL {
        repo.appending(path: universal ? ".build/apple/Products/Release" : ".build/release")
    }

    public struct Input: Sendable {
        public var spec: BundleSpec
        /// The built executable, e.g. `.build/release/DiskApp`. Its name
        /// need not match the app's (`DiskApp` → `Disk`).
        public var executable: URL
        /// Where `Sparkle.framework` and friends were built.
        public var productsDirectory: URL
        /// Copied to `Contents/Resources/<basename>`; the spec's `iconFile`
        /// must name it without the extension.
        public var icon: URL?
        /// Already-built app extensions, placed in `Contents/PlugIns` and
        /// version-stamped to match the app. SwiftPM cannot build an
        /// app-extension product, so these come from the consumer's
        /// xcodebuild step — `ota` places them, it does not build them.
        public var plugins: [URL]
        /// Second executables, placed in `Contents/Helpers/<basename>`:
        /// garita's agent-and-CLI beside its window. `ota release` signs
        /// them before the app (`Signing.helpers`), and what they link is
        /// embedded exactly as for the main executable.
        public var helpers: [URL]
        /// Frameworks embedded whether or not anything links them, for a
        /// binary that loads one at run time. `otool -L` cannot see a
        /// `dlopen`, so this is the one place the bundle is TOLD a fact
        /// rather than reading it — and it refuses to double a framework
        /// the binary does link.
        public var frameworks: [URL]

        public init(spec: BundleSpec, executable: URL, productsDirectory: URL,
                    icon: URL? = nil, plugins: [URL] = [], helpers: [URL] = [], frameworks: [URL] = []) {
            self.spec = spec
            self.executable = executable
            self.productsDirectory = productsDirectory
            self.icon = icon
            self.plugins = plugins
            self.helpers = helpers
            self.frameworks = frameworks
        }
    }

    /// Assemble `<out>`, replacing anything already there.
    @discardableResult
    public static func assemble(_ input: Input, into out: URL,
                                runner: Runner = SystemRunner(),
                                fileManager fm: FileManager = .default) throws -> AppBundle {
        guard fm.isExecutableFile(atPath: input.executable.path) else {
            throw Error(description: "no executable at \(input.executable.path) — build first")
        }
        // Everything named is checked before anything is removed or written.
        var helperNames: Set<String> = []
        for helper in input.helpers {
            guard fm.isExecutableFile(atPath: helper.path), AppBundle.isMachO(helper) else {
                throw Error(description: "no executable Mach-O at \(helper.path) — build the helper first")
            }
            guard helperNames.insert(helper.lastPathComponent).inserted else {
                throw Error(description: "two helpers named \(helper.lastPathComponent): both would be Contents/Helpers/\(helper.lastPathComponent)")
            }
        }
        for framework in input.frameworks where !fm.fileExists(atPath: framework.path) {
            throw Error(description: "no framework at \(framework.path)")
        }

        let contents = out.appending(path: "Contents")
        try? fm.removeItem(at: out)
        for dir in ["MacOS", "Frameworks", "Resources"] {
            try fm.createDirectory(at: contents.appending(path: dir), withIntermediateDirectories: true)
        }
        try fm.copyItem(at: input.executable, to: contents.appending(path: "MacOS/\(input.spec.name)"))
        if !input.helpers.isEmpty {
            try fm.createDirectory(at: contents.appending(path: "Helpers"), withIntermediateDirectories: true)
            for helper in input.helpers {
                try fm.copyItem(at: helper, to: contents.appending(path: "Helpers/\(helper.lastPathComponent)"))
            }
        }

        // What the binaries link MUST be embedded, and the binaries are the
        // ones that know. ccc's copy asserted only Sparkle; this asks the
        // question generically, so a framework added by a future consumer
        // fails loudly here instead of at launch on someone else's Mac. A
        // helper is asked too: from Contents/Helpers, the usual
        // `@executable_path/../Frameworks` rpath lands on the same directory.
        var linked: [String] = []
        for binary in [input.executable] + input.helpers {
            for framework in try Binary.linkedFrameworks(of: binary, runner: runner) where !linked.contains(framework) {
                let source = input.productsDirectory.appending(path: framework)
                guard fm.fileExists(atPath: source.path) else {
                    throw Error(description: "\(binary.lastPathComponent) links \(framework) but there is none in \(input.productsDirectory.path)")
                }
                // cp -R semantics: the framework's internal Versions/ symlinks
                // must survive, and `copyItem` preserves them.
                try fm.copyItem(at: source, to: contents.appending(path: "Frameworks/\(framework)"))
                linked.append(framework)
            }
        }
        for framework in input.frameworks {
            let name = framework.lastPathComponent
            guard !linked.contains(name) else {
                throw Error(description: "\(name) is linked, so it is already embedded from \(input.productsDirectory.path) — placing \(framework.path) too would ship two copies of one framework, and only one of them is the version the binary was built against")
            }
            try fm.copyItem(at: framework, to: contents.appending(path: "Frameworks/\(name)"))
        }

        // A feed is the promise of an update, and Sparkle is what keeps it.
        // A release-lane bundle without the framework installs fine and then
        // never updates — on a Mac that is not this one, with nothing to say.
        if input.spec.feed != nil,
           !fm.fileExists(atPath: contents.appending(path: "Frameworks/Sparkle.framework").path) {
            try? fm.removeItem(at: out)
            throw Error(description: "--feed makes this a release bundle, but there is no Sparkle.framework in it: nothing links it, and nothing placed it. An app that loads Sparkle at run time needs `--sparkle`; one that never updates needs no --feed")
        }

        if let icon = input.icon {
            guard fm.fileExists(atPath: icon.path) else {
                throw Error(description: "no icon at \(icon.path)")
            }
            try fm.copyItem(at: icon, to: contents.appending(path: "Resources/\(icon.lastPathComponent)"))
        }

        for plugin in input.plugins {
            guard fm.fileExists(atPath: plugin.path) else {
                throw Error(description: "no plug-in at \(plugin.path)")
            }
            let pluginsDir = contents.appending(path: "PlugIns")
            try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            let placed = pluginsDir.appending(path: plugin.lastPathComponent)
            try fm.copyItem(at: plugin, to: placed)
            // WidgetKit caches an extension's widget-KIND list keyed by
            // bundle version, so an appex shipping a static version means
            // adding or removing a widget never re-enumerates in the gallery
            // and the new widget silently never appears. Tie it to the app's.
            try stampVersion(of: placed, to: input.spec.version, fileManager: fm)
        }

        try input.spec.infoPlistXML().write(to: contents.appending(path: "Info.plist"))
        return AppBundle(out)
    }

    static func stampVersion(of bundle: URL, to version: Version, fileManager fm: FileManager) throws {
        let plistURL = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Error(description: "no readable Info.plist in \(bundle.lastPathComponent)")
        }
        plist["CFBundleShortVersionString"] = version.marketing
        plist["CFBundleVersion"] = String(version.build)
        let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try out.write(to: plistURL)
    }

    /// Every Mach-O in the bundle must carry every required arch. Prove it,
    /// do not assume it: a widget built by xcodebuild defaults to the active
    /// arch and can be thin inside a fat app, and the release then simply
    /// does not run on the Mac it was made universal for.
    public static func assertArchs(_ app: AppBundle, required: [String],
                                   runner: Runner = SystemRunner()) throws -> [(URL, [String])] {
        var checked: [(URL, [String])] = []
        for binary in app.machOFiles() {
            let archs = try Binary.archs(of: binary, runner: runner)
            let missing = required.filter { !archs.contains($0) }
            guard missing.isEmpty else {
                throw Error(description: "NOT UNIVERSAL: \(binary.path.replacingOccurrences(of: app.url.path + "/", with: "")) has [\(archs.joined(separator: " "))], missing \(missing.joined(separator: " "))")
            }
            checked.append((binary, archs))
        }
        guard !checked.isEmpty else {
            throw Error(description: "no Mach-O files found in \(app.url.path) — nothing was checked, which is not the same as passing")
        }
        return checked
    }
}
