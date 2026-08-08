import SwiftUI
import AppKit

/// Batch video compression.
///
/// Beyond multi-file, this fixes a silent data loss: `compressVideo` had
/// AVAssetExportPreset1280x720 hard-coded, so every clip — including 4K — was downscaled to
/// 720p with nothing in the UI saying so. Resolution is now an explicit, visible choice.
struct CompressVideosSheet: View {

    let candidates: [CompressCandidate]
    var onClose: () -> Void

    @State private var selection: Set<URL>
    @State private var options = VideoCompressOptions()
    @StateObject private var runner = CompressRunner()

    init(candidates: [CompressCandidate], onClose: @escaping () -> Void) {
        self.candidates = candidates
        self.onClose = onClose
        _selection = State(initialValue: Set(candidates.filter(\.isEligible).map(\.url)))
    }

    private var eligible: [CompressCandidate] { candidates.filter(\.isEligible) }
    private var chosen: [CompressCandidate] { eligible.filter { selection.contains($0.url) } }
    private var totalBefore: Int64 { chosen.reduce(0) { $0 + $1.byteSize } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompressSheetHeader(
                title: "Compress videos",
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

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(candidates) { c in
                    CompressFileRow(
                        candidate: c,
                        isSelected: selection.contains(c.url),
                        // No size estimate for video: it depends on codec, bitrate and
                        // content in ways a heuristic would get badly wrong. Showing a
                        // confident-looking wrong number is worse than showing none.
                        estimate: nil,
                        toggle: {
                            if selection.contains(c.url) { selection.remove(c.url) }
                            else { selection.insert(c.url) }
                        })
                }
            }
        }
        .frame(maxHeight: 210)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Resolution").font(.system(size: 11.5)).foregroundColor(.secondary)
                Picker("", selection: $options.quality) {
                    ForEach(VideoCompressOptions.Quality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                Text(options.quality.detail)
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
            }

            HStack(spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Container").font(.system(size: 11.5)).foregroundColor(.secondary)
                    Picker("", selection: $options.container) {
                        ForEach(VideoCompressOptions.Container.allCases) { c in
                            Text(c.label).tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Text("Name").font(.system(size: 11.5)).foregroundColor(.secondary)
                    .frame(width: 62, alignment: .leading)
                TextField("{name}-compressed", text: $options.nameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("{name} = original")
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !chosen.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ByteCountFormatter.string(fromByteCount: totalBefore, countStyle: .file)
                         + " to re-encode")
                        .font(.system(size: 12.5)).foregroundColor(.secondary)
                    Text("Video export can take a while — the originals are kept.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Compress \(chosen.count)") {
                let urls = chosen.map(\.url)
                Task { await runner.runVideos(urls, options: options) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
        }
    }
}
