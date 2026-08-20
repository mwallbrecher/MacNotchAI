import AppKit
import SwiftUI

// THESIS (L5) — the whisper surface: a thesis-owned, non-activating panel just
// below the notch. Deliberately NOT the main overlay window / stage machine:
// zero churn on main-owned UI, and the research layer stays visibly separate.
// (The main pill needs drag-snapshot immortality; this panel receives no drops,
// so it can be created and torn down freely.)
//
// Two contents, one surface — the two exposure channels of ARCHITECTURE §7:
//   · .suggestion — the PASSIVE whisper (gated by θ/policy)
//   · .ticker     — the SUMMONED top-3 view (no gate; solicited can't annoy)

@MainActor
final class WhisperWindow: NSPanel {

    init(contentSize: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Never steal focus — the user's keyboard stays in their app; accept rides
    /// a Carbon hotkey, dismiss is a click or the auto-fade.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Center below the notch, mirroring the main pill's anchor (notch bottom ≈ 37pt).
    func place(size: CGSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - 37 - size.height
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }
}

// MARK: - Content model

enum WhisperContent {
    case suggestion(IntentSuggestion)
    case ticker([TickerRow])
    /// Experience sampling immediately after an interaction (M5, study builds).
    case prompt(InSituPrompt)
    /// One-time card teaching the summon hotkey (E2).
    case hint
}

struct TickerRow: Identifiable {
    let id = UUID()
    let intentClass: IntentClass
    let probability: Double
    /// One-line "why": the strongest evidence contributions, humanised.
    let evidenceLine: String
    /// Every class resolves since the summon channel became the MVP; nil only when
    /// there is genuinely nothing actionable in front of the user.
    let suggestion: IntentSuggestion?
}

/// The three questions asked right after an affordance interaction.
///
/// Two measure EXPERIENCE — the wanted-versus-intrusive distinction that replaced
/// "would you have used it?", and the thing the reframed research question actually
/// turns on. The third measures CONTEXT, and it is what makes every affordance event
/// self-interpreting: without it, an event in a fortnight of continuous capture cannot
/// be told apart from an hour of video watching, and summon rates lose their
/// denominator.
struct InSituPrompt {
    enum Stage { case assessment, intrusive, context }
    enum FirstQuestion: String {
        case suggestionRelevant = "suggestion_relevant"
        case resultUseful = "result_useful"
    }

    let interactionID: UUID
    let channel: AffordanceChannel
    let rank: Int
    let intentClass: IntentClass
    let action: String
    /// What the participant did with the suggestion ("accepted" / "dismissed").
    let outcome: String
    /// A completed provider turn asks about the result. A dismissal or technical
    /// failure asks only whether the suggestion itself was relevant/wanted.
    let firstQuestion: FirstQuestion

    var stage: Stage = .assessment
    var firstAnswer: Bool?
    var intrusive: Bool?

    static let contextOptions = ["Reading / research", "Writing", "Email / messages",
                                 "Admin / organising", "Something else"]
}

// MARK: - Views

struct WhisperSuggestionView: View {
    let suggestion: IntentSuggestion
    /// Supplied by the controller so the bar and the actual dismiss timer are the same
    /// number. A bar that empties early or late would misreport how much time the
    /// participant had, which is exactly the quantity the study measures.
    let fadeSeconds: TimeInterval
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void
    @Environment(\.uiScale) private var scale

    @State private var startedAt = Date()
    /// Non-nil while the pointer rests on the whisper: the controller invalidates its
    /// timer then, so the bar has to stop too rather than keep draining.
    @State private var frozenAfter: TimeInterval?

    private func remainingFraction(at now: Date) -> Double {
        guard fadeSeconds > 0 else { return 0 }
        let spent = frozenAfter ?? now.timeIntervalSince(startedAt)
        return min(1, max(0, 1 - spent / fadeSeconds))
    }

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "globe")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            Text(suggestion.phrase)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 4 * scale)

            Button(action: onAccept) {
                HStack(spacing: 5 * scale) {
                    Text(suggestion.action.rawValue)
                        .font(.system(size: 12 * scale, weight: .semibold))
                    Text("⌥⏎")
                        .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4 * scale).padding(.vertical, 1.5 * scale)
                        .background(RoundedRectangle(cornerRadius: 4 * scale)
                            .fill(.white.opacity(0.18)))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10 * scale).padding(.vertical, 5 * scale)
                .background(Capsule().fill(Color.accentColor.opacity(0.85)))
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10 * scale, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 22 * scale, height: 22 * scale)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14 * scale).padding(.vertical, 9 * scale)
        .background(
            Capsule().fill(Color.black.opacity(0.92))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1 * scale))
        )
        .overlay(alignment: .bottom) { decayBar }
        .onHover { hovering in
            if hovering {
                frozenAfter = Date().timeIntervalSince(startedAt)
            } else {
                // The controller arms a FULL fade again on exit, so the bar refills
                // rather than resuming — otherwise it would claim less time than the
                // participant actually has.
                startedAt = Date()
                frozenAfter = nil
            }
            onHover(hovering)
        }
    }

    /// Sits inside the capsule, inset far enough to clear the rounded ends at any ui
    /// scale. `.animation` drives it from the clock instead of a stored animation, so
    /// freezing on hover is a value change rather than an animation to interrupt.
    private var decayBar: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.10))
                    Capsule()
                        .fill(.white.opacity(frozenAfter == nil ? 0.45 : 0.7))
                        .frame(width: geo.size.width * remainingFraction(at: context.date))
                }
            }
        }
        .frame(height: 2 * scale)
        .padding(.horizontal, 22 * scale)
        .padding(.bottom, 3.5 * scale)
        .allowsHitTesting(false)
    }
}

struct WhisperTickerView: View {
    let rows: [TickerRow]
    let onAccept: (IntentSuggestion) -> Void
    let onClose: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                Text("Current intent estimates")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4 * scale) {
                    HStack(spacing: 10 * scale) {
                        Text(label(for: row.intentClass))
                            .font(.system(size: 12 * scale, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 108 * scale, alignment: .leading)

                        // Model estimate — a bar, not a verdict. Empirical calibration
                        // is an analysis target, not a property claimed by this build.
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12))
                                Capsule().fill(Color.accentColor.opacity(0.85))
                                    .frame(width: max(3 * scale,
                                                      geo.size.width * row.probability))
                            }
                        }
                        .frame(height: 6 * scale)

                        Text(String(format: "%.0f%%", row.probability * 100))
                            .font(.system(size: 11 * scale, weight: .semibold,
                                          design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 34 * scale, alignment: .trailing)
                    }

                    if let suggestion = row.suggestion {
                        Button(action: { onAccept(suggestion) }) {
                            HStack(spacing: 5 * scale) {
                                Image(systemName: suggestion.action.icon)
                                Text(suggestion.action.rawValue)
                                Text("· \(suggestion.phrase)")
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                            .buttonStyle(.plain)
                            .font(.system(size: 11 * scale, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 9 * scale).padding(.vertical, 4 * scale)
                            .background(RoundedRectangle(cornerRadius: 6 * scale)
                                .fill(Color.accentColor.opacity(0.72)))
                    } else {
                        Text("No current, verifiable source")
                            .font(.system(size: 10 * scale))
                            .foregroundColor(.white.opacity(0.38))
                    }
                    Text(row.evidenceLine)
                        .font(.system(size: 10 * scale))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        .padding(14 * scale)
        .frame(width: 480 * scale, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1 * scale))
        )
    }

    private func label(for c: IntentClass) -> String {
        switch c {
        case .translation:   return "Translation"
        case .comprehension: return "Comprehension"
        case .discovery:     return "Discovery"
        }
    }
}

// MARK: - In-situ prompt (experience sampling, M5)

/// Three one-tap questions on the same non-activating surface as the whisper.
///
/// One question at a time, deliberately. A three-part form is a task; a single
/// yes/no that replaces itself is a reflex — and the whole point of sampling in
/// situ rather than at the exit interview is to catch the reaction before it turns
/// into a considered account.
///
/// Skipping is always one click away and is RECORDED as a skip rather than silently
/// dropped: which moments people decline to rate is itself data, and treating a
/// non-answer as missing-at-random would quietly bias the intrusiveness measure.
struct WhisperPromptView: View {
    let prompt: InSituPrompt
    let onAnswerYesNo: (Bool) -> Void
    let onAnswerContext: (String) -> Void
    let onSkip: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack {
                Text(question)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onSkip) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9 * scale, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Skip")
            }

            switch prompt.stage {
            case .assessment, .intrusive:
                HStack(spacing: 8 * scale) {
                    pill("Yes")  { onAnswerYesNo(true) }
                    pill("No")   { onAnswerYesNo(false) }
                    Spacer()
                }
            case .context:
                // Wraps: five options do not fit one row at this width.
                VStack(alignment: .leading, spacing: 6 * scale) {
                    ForEach(Array(InSituPrompt.contextOptions.enumerated()), id: \.offset) { _, option in
                        pill(option) { onAnswerContext(option) }
                    }
                }
            }
        }
        .padding(14 * scale)
        .frame(width: 380 * scale, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1 * scale))
        )
    }

    private var question: String {
        switch prompt.stage {
        case .assessment:
            return prompt.firstQuestion == .resultUseful
                ? "Was the AI result useful?"
                : "Was that suggestion relevant or wanted?"
        case .intrusive: return "Did it feel intrusive?"
        case .context:   return "What were you doing just now?"
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10 * scale).padding(.vertical, 4 * scale)
                .background(Capsule().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Summon hint (E2, discoverability)

/// Shown once, right after consent, on the surface where suggestions will actually
/// appear — so the hotkey is learned in the place it pays off rather than in a
/// settings pane the participant will never revisit.
///
/// Discoverability is risk 1 of the pivot: a summon hotkey nobody knows about is a
/// feature nobody uses, and then the guarantee the thesis rests on evaporates.
struct WhisperHintView: View {
    let onClose: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 12 * scale) {
            Image(systemName: "sparkles")
                .font(.system(size: 15 * scale))
                .foregroundColor(.white.opacity(0.8))

            VStack(alignment: .leading, spacing: 3 * scale) {
                Text("Press ⌃⌥⌘I whenever you want help")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundColor(.white)
                Text("Dragaway shows what it would suggest for whatever you're looking at. "
                   + "Nothing happens unless you pick something.")
                    .font(.system(size: 11 * scale))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4 * scale)

            Button(action: onClose) {
                Text("Got it")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10 * scale).padding(.vertical, 4 * scale)
                    .background(Capsule().fill(Color.accentColor.opacity(0.85)))
            }
            .buttonStyle(.plain)
        }
        .padding(14 * scale)
        .frame(width: 460 * scale, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1 * scale))
        )
    }
}
