import SwiftUI
import AppKit

/// Pieces shared by the image and video compression sheets. The sheets stay separate
/// because their options genuinely differ; only the chrome is common.

struct CompressSheetHeader: View {
    let title: String
    let subtitle: String
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// One file row. Ineligible files are shown greyed out WITH the reason rather than hidden:
/// a user who dropped five files and sees three should be told why, not left guessing.
struct CompressFileRow: View {
    let candidate: CompressCandidate
    let isSelected: Bool
    let estimate: String?
    var toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: candidate.isEligible
                  ? (isSelected ? "checkmark.square.fill" : "square")
                  : "square.slash")
                .font(.system(size: 13))
                .foregroundColor(candidate.isEligible
                                 ? (isSelected ? .accentColor : .secondary)
                                 : .secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundColor(candidate.isEligible ? .primary : .secondary)
                if let reason = candidate.ineligibleReason {
                    Text(reason).font(.system(size: 10.5)).foregroundColor(.secondary)
                } else if let dims = candidate.dimensionText {
                    Text(dims).font(.system(size: 10.5)).foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            if candidate.isEligible {
                Text(candidate.sizeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                if let estimate {
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(.secondary)
                    Text(estimate)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 66, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { if candidate.isEligible { toggle() } }
        .opacity(candidate.isEligible ? 1 : 0.55)
    }
}

/// Progress + result. A partial batch is reported honestly: successes and failures are
/// listed side by side rather than collapsing into one "done".
struct CompressProgressView: View {
    @ObservedObject var runner: CompressRunner
    var onClose: () -> Void

    private var failures: [CompressRunner.Outcome] { runner.outcomes.filter { !$0.ok } }
    private var successes: [CompressRunner.Outcome] { runner.outcomes.filter(\.ok) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if runner.running {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(runner.doneCount),
                                 total: Double(max(runner.totalCount, 1)))
                    Text("\(runner.doneCount) of \(runner.totalCount) · \(runner.currentName)")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(failures.isEmpty ? .green : .orange)
                    Text(failures.isEmpty
                         ? "Compressed \(successes.count) file\(successes.count == 1 ? "" : "s")"
                         : "\(successes.count) done, \(failures.count) failed")
                        .font(.system(size: 13, weight: .semibold))
                }

                if !successes.isEmpty, runner.savedBytes > 0 {
                    Text("Saved " + ByteCountFormatter.string(fromByteCount: runner.savedBytes,
                                                              countStyle: .file))
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }

                if !failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(failures) { f in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.url.lastPathComponent)
                                        .font(.system(size: 11.5)).lineLimit(1)
                                    Text(f.error ?? "Failed")
                                        .font(.system(size: 10.5)).foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }

                HStack {
                    if let first = successes.first?.output {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(successes.compactMap(\.output))
                            _ = first
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Button("Done", action: onClose)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minHeight: 90, alignment: .top)
    }
}
