import Foundation

/// The stable-key appcast: `<prefix>/<App>-latest.zip` + `<prefix>/appcast.xml`
/// on the CDN, overwritten every release so the namespace never grows.
/// Versioned zips accumulate locally (the signing archive) and on GitHub
/// Releases (the record).
public enum Appcast {
    public static let sparkleToolsVersion = "2.9.4"

    public static func toolsBin(home: URL = .homeDirectory) -> URL {
        home.appending(path: "Library/Caches/ota-sparkle-tools/\(sparkleToolsVersion)/bin")
    }

    /// Fetch Sparkle's tools once per version. Two argv commands rather than
    /// `sh -c "curl … | tar …"`: a plan step is printable and runnable without
    /// a shell, and an interpolated path never has to survive quoting.
    public static func fetchToolsPlan(into bin: URL) -> [Command] {
        let parent = bin.deletingLastPathComponent()
        let tarball = parent.appending(path: "Sparkle-\(sparkleToolsVersion).tar.xz")
        let url = "https://github.com/sparkle-project/Sparkle/releases/download/\(sparkleToolsVersion)/Sparkle-\(sparkleToolsVersion).tar.xz"
        return [
            Command("mkdir", "-p", parent.path),
            Command("curl", "-fsSL", "-o", tarball.path, url),
            Command("tar", "-xJf", tarball.path, "-C", parent.path),
            Command("rm", "-f", tarball.path),
        ]
    }

    /// The feed MUST be single-item, and that is a correctness property:
    /// every item's enclosure is rewritten to the SAME stable key, so only
    /// the newest item can describe what that key holds — an older item
    /// keeps its own `length=` and EdDSA signature while describing bytes
    /// that no longer exist there. `--maximum-versions 1` does not
    /// guarantee it (disk v0.6.0: an arm64-only older item was judged still
    /// relevant hardware-wise and kept), and `generate_appcast` MERGES into
    /// any appcast it finds. So: archive every other zip, delete the feed,
    /// regenerate from empty, then assert one item.
    ///
    /// "Every other zip" is `*.zip`, not `<App>-v*.zip` as the shell copies
    /// had it: `generate_appcast` scans the directory, not a name pattern, so
    /// a zip left behind under any other name is one it would happily publish
    /// a second item for.
    public static func generatePlan(feedDir: URL, currentZip: URL, prefixURL: String, toolsBin: URL) -> [Step] {
        let old = feedDir.appending(path: "old_updates")
        let stem = currentZip.lastPathComponent
        return [
            .run(Command("mkdir", "-p", old.path)),
            .run(Command("cp", "-f", currentZip.path, feedDir.path + "/")),
            .run(Command("find", [feedDir.path, "-maxdepth", "1", "-name", "*.zip", "!", "-name", stem,
                                  "-exec", "mv", "{}", old.path + "/", ";"])),
            .run(Command("rm", "-f", feedDir.appending(path: "appcast.xml").path)),
            // Streams: it signs every zip it finds and says so, and on a cold
            // cache it is the first thing that takes real time.
            .stream(Command(toolsBin.appending(path: "generate_appcast").path,
                            "--maximum-versions", "1", "--maximum-deltas", "0",
                            "--download-url-prefix", prefixURL, feedDir.path)),
        ]
    }

    public static func itemCount(xml: String) -> Int {
        xml.components(separatedBy: "<item>").count - 1
    }

    /// Point the enclosure at the stable key. The EdDSA signature covers
    /// content, so the filename is irrelevant to Sparkle.
    public static func rewriteToStableKey(xml: String, prefixURL: String, appName: String) -> String {
        let prefix = prefixURL.hasSuffix("/") ? prefixURL : prefixURL + "/"
        let pattern = "(url=\"" + NSRegularExpression.escapedPattern(for: prefix) + ")"
            + NSRegularExpression.escapedPattern(for: appName) + "-v[^\"]+\\.zip"
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: xml, range: NSRange(xml.startIndex..., in: xml),
                                           withTemplate: "$1" + appName + "-latest.zip")
    }

    public static func stableKey(prefixURL: String, appName: String) -> String {
        let prefix = prefixURL.hasSuffix("/") ? prefixURL : prefixURL + "/"
        return prefix + appName + "-latest.zip"
    }

    /// The two `share` lines. `--permanent` exempts both keys from the CDN's
    /// 30-day sweep (mux's artifacts were eaten by it once); uploads purge
    /// the edge cache and `.xml` gets a short cache by worker policy.
    ///
    /// The ZIP GOES FIRST. Both keys are overwritten, so there is a window
    /// where one is new and the other old; zip-then-xml makes that window
    /// "the key holds the new bytes, the feed still describes the old ones",
    /// which no installed copy acts on. The other order publishes a feed
    /// describing bytes the key does not yet hold, and every copy that polls
    /// in that window fails its update.
    public static func publishPlan(zip: URL, appcast: URL, prefix: String, appName: String) -> [Step] {
        [
            .stream(Command("share", zip.path, "\(prefix)/\(appName)-latest.zip", "--permanent")),
            .stream(Command("share", appcast.path, "\(prefix)/appcast.xml", "--permanent")),
        ]
    }
}
