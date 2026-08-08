import SwiftUI
import AppKit

/// Batch image compression. Replaces the old single-file NSAlert, which acted only on the
/// session's primary file — dropping five photos and pressing Compress processed one.
struct CompressImagesSheet: View {

    let candidates: [CompressCandidate]
    var onClose: () -> Void

    @State private var selection: Set<URL>
    @State private var options = ImageCompressOptions(maxDimension: 1024)
    @StateObject private var runner = CompressRunner()

    init(candidates: [CompressCandidate], onClose: @escaping () -> Void) {
        self.candidates = candidates
        self.onClose = onClose
        // Everything eligible starts selected — the common case is "all of them".
        _selection = State(initialValue: Set(candidates.filter(\.isEligible).map(\.url)))
    }

    private var eligible: [CompressCandidate] { candidates.filter(\.isEligible) }
    private var chosen: [CompressCandidate] { eligible.filter { selection.contains($0.url) } }

    private var totalBefore: Int64 { chosen.reduce(0) { $0 + $1.byteSize } }
    private var totalAfter: Int64? {
        let parts = chosen.map { CompressEstimate.image($0, options) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompressSheetHeader(
                title: "Compress images",
                subtitle: "\(chosen.count) of \(eligible.count) selected",
                onClose: onClose)

            Divider().padding(.vertical, 12)

            if runner.running || !runner.outcomes.isEmpty {
                CompressProgressView(runner: runner, onClose: onClose)
            } else {
                fileList
                Divider().padding(.vertical, 12)
                settings
                Divider().padding(.vertical, 12)
                footer
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: Files

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(candidates) { c in
                    CompressFileRow(
                        candidate: c,
                        isSelected: selection.contains(c.url),
                        estimate: c.isEligible
                            ? CompressEstimate.text(for: CompressEstimate.image(c, options))
                            : nil,
                        toggle: {
                            if selection.contains(c.url) { selection.remove(c.url) }
                            else { selection.insert(c.url) }
                        })
                }
            }
        }
        .frame(maxHeight: 210)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Max size").font(.system(size: 11.5)).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { options.maxDimension },
                        set: { options.maxDimension = $0 })) {
                        ForEach(ImageCompressOptions.sizeChoices, id: \.label) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Format").font(.system(size: 11.5)).foregroundColor(.secondary)
                    Picker("", selection: $options.format) {
                        ForEach(ImageCompressOptions.Format.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                Spacer()
            }

            // The transparency trap, stated where the choice is made: JPEG has no alpha, so
            // a PNG logo silently gains a background. Previously this always happened and
            // was never mentioned anywhere.
            if options.format.losesTransparency,
               chosen.contains(where: { $0.url.pathExtension.lowercased() == "png" }) {
                Label("JPEG has no transparency — PNGs will get a background. Choose PNG or “Keep original” to preserve it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if options.format.usesQuality {
                HStack(spacing: 10) {
                    Text("Quality").font(.system(size: 11.5)).foregroundColor(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Slider(value: $options.quality, in: 0.3...1.0)
                    Text("\(Int(options.quality * 100)) %")
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
            }

            HStack(spacing: 10) {
                Text("Name").font(.system(size: 11.5)).foregroundColor(.secondary)
                    .frame(width: 52, alignment: .leading)
                TextField("{name}-compressed", text: $options.nameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("{name} = original")
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if !chosen.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(ByteCountFormatter.string(fromByteCount: totalBefore, countStyle: .file))
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(.secondary)
                        Text(CompressEstimate.text(for: totalAfter)).fontWeight(.semibold)
                    }
                    .font(.system(size: 12.5))
                    Text("Estimated — actual size depends on the image content.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Compress \(chosen.count)") {
                let urls = chosen.map(\.url)
                Task { await runner.runImages(urls, options: options) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
        }
    }
}
