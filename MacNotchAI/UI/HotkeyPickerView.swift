import SwiftUI
import AppKit

// MARK: - Hotkey picker sheet

struct HotkeyPickerView: View {
    var onDismiss: () -> Void

    /// Local copy of modifier selection — saved to HotkeyManager only on "Save".
    @State private var selectedMods: NSEvent.ModifierFlags = HotkeyManager.shared.requiredModifiers

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.accentColor)
                Text("Drag Hotkey")
                    .font(.title2.bold())
                Text("When set, the pill only appears while\nyou hold the chosen key during a drag.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.horizontal, 28)

            Divider().padding(.vertical, 20)

            // ── Modifier toggles ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                Text("Required modifier")
                    .font(.headline)

                HStack(spacing: 10) {
                    ModifierToggle(symbol: "⌃", label: "Control",
                                   flag: .control, selection: $selectedMods)
                    ModifierToggle(symbol: "⌥", label: "Option",
                                   flag: .option,  selection: $selectedMods)
                    ModifierToggle(symbol: "⇧", label: "Shift",
                                   flag: .shift,   selection: $selectedMods)
                    ModifierToggle(symbol: "⌘", label: "Command",
                                   flag: .command, selection: $selectedMods)
                }

                // Context line beneath the buttons
                Group {
                    if selectedMods.isEmpty {
                        Label("No modifier — pill appears for every drag.",
                              systemImage: "info.circle")
                    } else {
                        Label("Hold \(HotkeyManager.displayString(for: selectedMods)) while dragging to show the pill.",
                              systemImage: "checkmark.circle")
                            .foregroundColor(.accentColor)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .animation(.easeInOut(duration: 0.15), value: selectedMods.rawValue)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)

            // ── Action buttons ──────────────────────────────────────────────────
            HStack(spacing: 10) {
                Button("Clear Hotkey") {
                    HotkeyManager.shared.clear()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Save") {
                    HotkeyManager.shared.requiredModifiers = selectedMods
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 380)
    }
}

// MARK: - Modifier toggle button

private struct ModifierToggle: View {
    let symbol: String
    let label: String
    let flag: NSEvent.ModifierFlags
    @Binding var selection: NSEvent.ModifierFlags

    private var isOn: Bool { selection.contains(flag) }

    var body: some View {
        Button {
            var updated = selection
            if isOn { updated.remove(flag) } else { updated.insert(flag) }
            selection = updated
        } label: {
            VStack(spacing: 4) {
                Text(symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(width: 76, height: 54)
            .foregroundColor(isOn ? .accentColor : .primary)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Color.accentColor : Color.primary)
        .background(isOn ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isOn)
    }
}
