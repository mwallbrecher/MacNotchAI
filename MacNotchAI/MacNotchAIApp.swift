import SwiftUI

@main
struct MacNotchAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu-bar icon is a custom NSStatusItem managed in AppDelegate (not a
        // MenuBarExtra) so a left-click can RESTORE a minimized session instead of
        // always opening the menu. See AppDelegate.setupStatusItem().
        Settings {
#if THESIS_STUDY_BUILD
            // SwiftUI constructs the Settings scene before AppDelegate receives
            // applicationDidFinishLaunching. Keep the built-artefact verification
            // seam genuinely headless: SettingsView owns provider/keychain singletons
            // that may block or prompt before the argument guard can terminate.
            if ProcessInfo.processInfo.arguments.contains("--intent-golden-checks") {
                EmptyView()
            } else {
                SettingsView()
            }
#else
            SettingsView()
#endif
        }
    }
}
