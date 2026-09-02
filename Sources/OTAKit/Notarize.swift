import Foundation

/// Notarize, staple, zip — the sequence every app copied verbatim.
public enum Notarize {
    /// `ditto -c -k --sequesterRsrc --keepParent`. `--sequesterRsrc` is
    /// load-bearing: without it extended attributes ride along as
    /// AppleDouble entries, `ditto -x` merges them invisibly (every check on
    /// the building Mac passes), but Archive Utility — what Safari extracts
    /// with — writes them as literal `._*` files inside Sparkle.framework's
    /// root and Gatekeeper rejects "unsealed contents present in the root
    /// directory of an embedded framework" (mux v0.2.0, 2026-07-09).
    public static func zip(app: URL, to zip: URL) -> Command {
        Command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path)
    }

    /// Submit, wait, staple, validate, Gatekeeper-check, then RE-ZIP the
    /// stapled app so the ticket travels with it. The notarytool keychain
    /// profile is per Apple account, not per app (`mux-notary` serves the
    /// fleet; a leftover name).
    public static func plan(app: URL, zip: URL, profile: String) -> [Command] {
        [
            Self.zip(app: app, to: zip),
            Command("xcrun", "notarytool", "submit", zip.path, "--keychain-profile", profile, "--wait"),
            Command("xcrun", "stapler", "staple", app.path),
            Command("xcrun", "stapler", "validate", app.path),
            Command("spctl", "-a", "-vvv", "--type", "execute", app.path),
            Command("rm", "-f", zip.path),
            Self.zip(app: app, to: zip),
        ]
    }
}
