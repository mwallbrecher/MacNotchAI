import SwiftUI
import AppKit

// MARK: - Hotkey picker sheet

struct HotkeyPickerView: View {
    var onDismiss: () -> Void

    @State private var selectedMods:  NSEvent.ModifierFlags = HotkeyManager.shared.requiredModifiers
    @State private var requiresSpace: Bool                  = HotkeyManager.shared.requiresSpacebar

    private var nothingSelected: Bool { selectedMods.isEmpty && !requiresSpace }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────
            VStack(alignment: .center, spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.accentColor)

                Text("Drag Hotkey")
                    .font(.title2.bold())

                Text("When set, the pill only appears while you hold\nthe selected key(s) at the start of a drag.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.horizontal, 28)

            Divider()
                .padding(.vertical, 20)

            // ── Key selection ────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 14) {

                Text("Required key(s) during drag")
                    .font(.headline)

                // ── Modifier row ────────────────────────────────────────────────
                HStack(spacing: 8) {
                    ModifierToggle(symbol: "⌃", label: "Control",
                                   flag: .control, selection: $selectedMods)
                    ModifierToggle(symbol: "⌥", label: "Option",
                                   flag: .option,  selection: $selectedMods)
                    ModifierToggle(symbol: "⇧", label: "Shift",
                                   flag: .shift,   selection: $selectedMods)
                    ModifierToggle(symbol: "⌘", label: "Command",
                                   flag: .command, selection: $selectedMods)
                }

                // ── Spacebar row ─────────────────────────────────────────────────
                SpacebarToggle(isOn: $requiresSpace)

                Divider()

                // ── Preview ──────────────────────────────────────────────────────
                Group {
                    if nothingSelected {
                        Label(
                            "No key set — pill appears for every drag.",
                            systemImage: "info.circle"
                        )
                        .foregroundColor(.secondary)
                    } else {
                        Label(
                            "Hold \(HotkeyManager.displayString(for: selectedMods, space: requiresSpace)) while dragging a file to show the pill.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundColor(.accentColor)
                    }
                }
                .font(.callout)
                .animation(.easeInOut(duration: 0.15), value: nothingSelected)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)

            // ── Action buttons ───────────────────────────────────────────────────
            HStack(spacing: 10) {
                Button("Clear") {
                    HotkeyManager.shared.clear()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Save") {
                    HotkeyManager.shared.requiredModifiers = selectedMods
                    HotkeyManager.shared.requiresSpacebar  = requiresSpace
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 420)
    }
}

// MARK: - Modifier key toggle (⌃ ⌥ ⇧ ⌘)

private struct ModifierToggle: View {
    let symbol: String
    let label:  String
    let flag:   NSEvent.ModifierFlags
    @Binding var selection: NSEvent.ModifierFlags

    private var isOn: Bool { selection.contains(flag) }

    var body: some View {
        Button {
            var updated = selection
            if isOn { updated.remove(flag) } else { updated.insert(flag) }
            selection = updated
        } label: {
            VStack(spacing: 5) {
                Text(symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundColor(isOn ? .accentColor : .primary)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Color.accentColor : Color.primary)
        .background(isOn ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isOn)
    }
}

// MARK: - Spacebar toggle

private struct SpacebarToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Text("␣")
                    .font(.system(size: 22, weight: .medium))
                Text("Space Bar")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundColor(isOn ? .accentColor : .primary)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Color.accentColor : Color.primary)
        .background(isOn ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isOn)
    }
}
