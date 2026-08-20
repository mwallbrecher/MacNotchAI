import AppKit
#if canImport(Sparkle) && !THESIS_STUDY_BUILD
import Sparkle
#endif

/// In-app auto-update via Sparkle 2.
///
/// The app is a Developer-ID direct download (not the Mac App Store), so Sparkle is the
/// standard way to ship updates: a background check finds a newer build in the appcast
/// feed, downloads the notarized DMG, verifies its EdDSA signature, and installs it on
/// relaunch — the user just clicks "Install & Relaunch", no re-download from the site.
///
/// Because the app is NOT sandboxed, `SPUStandardUpdaterController` works directly with
/// no XPC Installer/Downloader services. It reads `SUFeedURL` + `SUPublicEDKey` from
/// Info.plist (set as INFOPLIST_KEY_* build settings). See SPARKLE_SETUP.md.
///
/// The whole class is gated on `canImport(Sparkle)` with a no-op fallback, so the
/// project builds before the SPM package has been added in Xcode; once the package is
/// there the real updater lights up with no code change.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

#if canImport(Sparkle) && !THESIS_STUDY_BUILD
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = false   // always let the user confirm install
        updater.updateCheckInterval = 60 * 60 * 6       // background check every 6h
    }

    /// Menu action — presents Sparkle's "checking / update available" UI. Sparkle greys
    /// its own item out while a check is in flight, so this is always safe to call.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Whether a manual check can run right now (drives the menu item's enabled state).
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// Verification seam for the study status UI and the release checklist.
    var isPermanentlyDisabled: Bool { false }
#else
    // A thesis build always compiles this stub even if a future merge reintroduces
    // the package. There is therefore no Sparkle symbol reference, controller, feed
    // request, or UI path in the research artefact.
    private init() {}
    func checkForUpdates() {}
    var canCheckForUpdates: Bool { false }
    var isPermanentlyDisabled: Bool { true }
#endif
}
