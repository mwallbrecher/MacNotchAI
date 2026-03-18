import SwiftUI

struct MenuBarView: View {

    // Tracks the wall-clock epoch at which the pill re-enables.
    // 0 (default) = not disabled.
    @AppStorage("disabledUntil") private var disabledUntil: Double = 0

    private var isDisabled: Bool {
        disabledUntil > Date().timeIntervalSince1970
    }

    private var minutesLeft: Int {
        max(1, Int(ceil((disabledUntil - Date().timeIntervalSince1970) / 60)))
    }

    var body: some View {
        VStack(spacing: 4) {

            // ── App title ──────────────────────────────────────────────────────
            VStack(spacing: 2) {
                Text("AI Drop")
                    .font(.headline)
                if isDisabled {
                    Text("Paused · \(minutesLeft) min left")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 4)

            Divider()

            // ── Provider / settings ────────────────────────────────────────────
            Button("Change Language Model") {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }

            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Divider()

            // ── Disable / hotkey controls ──────────────────────────────────────
            if isDisabled {
                // Replace the submenu with a single "re-enable" action while paused
                Button("Re-enable Now") {
                    disabledUntil = 0
                }
            } else {
                Menu("Disable for…") {
                    Button("5 minutes")  { disableFor(5)  }
                    Button("15 minutes") { disableFor(15) }
                    Button("30 minutes") { disableFor(30) }
                    Button("1 hour")     { disableFor(60) }
                }
            }

            // Hotkey button — label morphs to show the current hotkey when set
            Button(HotkeyManager.shared.isEnabled
                    ? "Hotkey: \(HotkeyManager.shared.displayString)…"
                    : "Add Hotkey…") {
                NotificationCenter.default.post(name: .showHotkeyPicker, object: nil)
            }

            Divider()

            // ── Quit ───────────────────────────────────────────────────────────
            Button("Quit AI Drop") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(minWidth: 185)
    }

    // MARK: - Helpers

    private func disableFor(_ minutes: Int) {
        disabledUntil = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
    }
}
