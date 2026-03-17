import SwiftUI

@main
struct MacNotchAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("AI Drop", systemImage: "sparkles") {
            MenuBarView()
        }

        Settings {
            SettingsView()
        }
    }
}
