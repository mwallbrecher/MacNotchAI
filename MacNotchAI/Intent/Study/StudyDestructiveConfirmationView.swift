import SwiftUI

/// One exact, case-sensitive gate shared by participant-owned destructive actions.
/// Keeping the predicate outside either button prevents their confirmation semantics
/// from drifting apart when the explanatory copy changes.
enum StudyTypedConfirmation {
    static let phrase = "CONFIRM"

    static func accepts(_ text: String) -> Bool {
        text == phrase
    }
}

struct StudyTypedConfirmationField: View {
    @Binding var text: String
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            Text("Type CONFIRM to continue")
                .font(.caption.weight(.semibold))
            TextField(StudyTypedConfirmation.phrase, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }
}

struct StudyWithdrawalConfirmationView: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.uiScale) private var scale
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                Text("Stop taking part?")
                    .font(.title2.weight(.semibold))
                Text("You’re about to stop participating in this study. Recording will stop immediately, and your participation and contribution to my research will end. Existing study data will remain on this Mac and will only be used if you choose to send it. That is okay, but be aware that this can’t be undone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            StudyTypedConfirmationField(text: $confirmation)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stop taking part", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!StudyTypedConfirmation.accepts(confirmation))
            }
        }
        .padding(22 * scale)
        .frame(width: 500 * scale)
    }
}
