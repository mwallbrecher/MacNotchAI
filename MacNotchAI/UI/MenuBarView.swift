import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("AI Drop")
                .font(.headline)
                .padding(.bottom, 4)

            Divider()

            Button("AI Setup...") {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }

            Button("Settings...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit AI Drop") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(minWidth: 160)
    }
}
