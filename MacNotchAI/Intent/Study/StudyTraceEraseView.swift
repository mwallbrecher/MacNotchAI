import SwiftUI

struct StudyTraceEraseView: View {
    let onErase: (TimeInterval) -> Void
    let onCancel: () -> Void

    @Environment(\.uiScale) private var scale
    @State private var minutes = 60.0
    @State private var confirmation = ""

    private var durationLabel: String {
        let value = Int(minutes)
        if value < 60 { return "\(value) minutes" }
        let hours = value / 60
        let remainder = value % 60
        if remainder == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours) h \(remainder) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                Text("Erase recent traces")
                    .font(.title2.weight(.semibold))
                Text("Permanently remove the most recent recording interval from this Mac and every future study export.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10 * scale) {
                Text("Erase the last \(durationLabel)")
                    .font(.headline)
                Slider(value: $minutes, in: 5...240, step: 5)
                HStack {
                    Text("5 min")
                    Spacer()
                    Text("4 h")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10 * scale) {
                Text("You’re about to permanently erase the selected portion of your study traces. All data from that period will be lost. That is okay, but be aware that this can’t be undone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                StudyTypedConfirmationField(text: $confirmation)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Erase last \(durationLabel)", role: .destructive) {
                    onErase(minutes * 60)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!StudyTypedConfirmation.accepts(confirmation))
            }
        }
        .padding(22 * scale)
        .frame(width: 480 * scale)
    }
}
