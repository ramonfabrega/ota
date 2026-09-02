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

    /// Fetch Sparkle's tools once per version.
    public static func fetchToolsPlan(into bin: URL) -> [Command] {
        let parent = bin.deletingLastPathComponent()
        let url = "https://github.com/sparkle-project/Sparkle/releases/download/\(sparkleToolsVersion)/Sparkle-\(sparkleToolsVersion).tar.xz"
        return [
            Command("mkdir", "-p", parent.path),
            Command("sh", "-c", "curl -fsSL \(url) | tar -xJ -C \"\(parent.path)\""),
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
    public static func generatePlan(feedDir: URL, currentZip: URL, prefixURL: String, toolsBin: URL) -> [Command] {
        let old = feedDir.appending(path: "old_updates")
        let stem = currentZip.lastPathComponent
        return [
            Command("mkdir", "-p", old.path),
            Command("cp", "-f", currentZip.path, feedDir.path + "/"),
            Command("find", [feedDir.path, "-maxdepth", "1", "-name", "*-v*.zip", "!", "-name", stem,
                             "-exec", "mv", "{}", old.path + "/", ";"]),
            Command("rm", "-f", feedDir.appending(path: "appcast.xml").path),
            Command(toolsBin.appending(path: "generate_appcast").path,
                    "--maximum-versions", "1", "--maximum-deltas", "0",
                    "--download-url-prefix", prefixURL, feedDir.path),
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

    /// The two `share` lines. `--permanent` exempts both keys from the CDN's
    /// 30-day sweep (mux's artifacts were eaten by it once); uploads purge
    /// the edge cache and `.xml` gets a short cache by worker policy.
    public static func publishPlan(zip: URL, appcast: URL, prefix: String, appName: String) -> [Command] {
        [
            Command("share", zip.path, "\(prefix)/\(appName)-latest.zip", "--permanent"),
            Command("share", appcast.path, "\(prefix)/appcast.xml", "--permanent"),
        ]
    }
}
