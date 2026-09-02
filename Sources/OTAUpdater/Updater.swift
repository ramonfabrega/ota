import AppKit
import OTA
import Sparkle
import SwiftUI

/// Self-update, the fleet's shape: installed copies poll the CDN appcast
/// (`SUFeedURL` in Info.plist) on Sparkle's schedule and use its standard
/// UI, so a window appears only when there is something to say. The one
/// piece of app surface is "Check for Updates…" in the app menu.
///
/// GATED on the bundle: a bare `swift build` executable has no Info.plist,
/// and Sparkle answers that with a MODAL alert on startup that blocks the
/// main thread. In an app whose agent face is a unix socket the only symptom
/// was "the socket never answers" (ccc, 2026-09-02, found by `sample`). So
/// the dev lane runs without Sparkle, and "which lane is this" is read off
/// the plist — never a separate flag that could disagree with it.
@MainActor
public final class Updater {
    public let controller: SPUStandardUpdaterController?

    public var isEnabled: Bool { controller != nil }

    public init(bundle: Bundle = .main) {
        let bundled = bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = bundled
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    public var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    public func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// AppKit face: the menu item, wired to Sparkle's own action so its
    /// enabled state follows `canCheckForUpdates` through validation.
    /// Disabled, with the reason as its title, on the dev lane — which is a
    /// bundle without the feed keys as well as no bundle at all, and "dev
    /// build" is the wording that covers both (ccc's, and it is the case
    /// that actually happens).
    public func menuItem() -> NSMenuItem {
        guard let controller else {
            let item = NSMenuItem(title: "Check for Updates… (dev build)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        let item = NSMenuItem(title: "Check for Updates…",
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = controller
        return item
    }
}

/// SwiftUI face: `.commands { CheckForUpdatesCommand(updater: updater) }`.
public struct CheckForUpdatesCommand: Commands {
    let updater: Updater

    public init(updater: Updater) { self.updater = updater }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updater.isEnabled ? "Check for Updates…" : "Check for Updates… (dev build)") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheck)
        }
    }
}
