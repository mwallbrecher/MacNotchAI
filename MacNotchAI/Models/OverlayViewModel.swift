import SwiftUI
import Combine

/// Shared state that drives which stage the overlay is in.
/// AppDelegate writes to it; OverlayView reads from it.
@MainActor
class OverlayViewModel: ObservableObject {
    static let shared = OverlayViewModel()
    private init() {}

    enum Stage {
        case waitingForDrop
        case chips(url: URL, actions: [AIAction])
        case loading(url: URL, action: AIAction)
        case result(url: URL, action: AIAction, text: String)
        case error(url: URL, message: String)

        /// Whether the right-column result panel should be visible.
        var showsRightColumn: Bool {
            switch self {
            case .loading, .result, .error: return true
            default: return false
            }
        }

        var fileURL: URL? {
            switch self {
            case .chips(let u, _), .loading(let u, _),
                 .result(let u, _, _), .error(let u, _): return u
            default: return nil
            }
        }

        /// Stable integer used as SwiftUI animation value driver on stage changes.
        var tag: Int {
            switch self {
            case .waitingForDrop: return 0
            case .chips:          return 1
            case .loading:        return 2
            case .result:         return 3
            case .error:          return 4
            }
        }
    }

    @Published var stage: Stage = .waitingForDrop
    /// True while a file is physically dragged over the Stage-1 pill.
    @Published var isDragHovering = false
    /// True from the moment a drag-OUT gesture starts until the drag ends.
    /// AppDelegate watches this to close the session after the drop.
    @Published var isDraggingOut = false
    /// Text typed into the custom-prompt field in the result column.
    @Published var customPrompt: String = ""
    /// Jelly wobble scale applied at OverlayView level (outside clipShape) so
    /// the pill can overflow its layout frame without being clipped.
    @Published var jellyX: CGFloat = 1.0
    @Published var jellyY: CGFloat = 1.0

    // ── Singleton jelly task ─────────────────────────────────────────────────
    // Owned here — NOT in WaitingPillView — so only ONE task ever exists.
    //
    // Why this matters: dismissAnimated() fades the old window over 0.14 s.
    // During that window the old WaitingPillView is still live and still
    // observes isDragHovering. If the user starts a new drag immediately, a
    // second WaitingPillView appears in the new window. Both views would fire
    // their own animation tasks for the same isDragHovering change → two
    // concurrent withAnimation{} blocks targeting jellyX/Y → SwiftUI
    // invariant violation → _crashOnException.
    //
    // With the task stored here, startJellyHover() always cancels the running
    // task before creating a new one. No matter how many view instances call
    // it, exactly one task is alive at any time.
    private var jellyTask: Task<Void, Never>?

    func startJellyHover() {
        jellyTask?.cancel()
        jellyTask = Task { @MainActor in
            do {
                // Phase 1 — impact: cursor enters, pill squashes outward
                withAnimation(.spring(response: 0.15, dampingFraction: 0.55)) {
                    self.jellyX = 1.12; self.jellyY = 0.86
                }
                try await Task.sleep(nanoseconds: 120_000_000)

                // Phase 2 — rebound: liquid springs back through overshoot
                withAnimation(.spring(response: 0.28, dampingFraction: 0.48)) {
                    self.jellyX = 0.94; self.jellyY = 1.09
                }
                try await Task.sleep(nanoseconds: 170_000_000)

                // Phase 3 — settle: return to exact neutral and stay there.
                // No looping — a moving pill makes it harder to aim the drop.
                // The hitbox (NSView.bounds = 288×96) never changes with
                // scaleEffect, but a still pill is easier to target visually.
                withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                    self.jellyX = 1.0; self.jellyY = 1.0
                }
                // Task ends — pill is perfectly still while cursor hovers.
            } catch {
                // Cancelled (cursor left mid-wobble). stopJellyHover() will
                // snap back to neutral so the pill is never stuck mid-squash.
            }
        }
    }

    func stopJellyHover() {
        jellyTask?.cancel()
        jellyTask = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            jellyX = 1.0; jellyY = 1.0
        }
    }

    func setChips(url: URL) {
        stage = .chips(url: url, actions: FileInspector.suggestedActions(for: url))
        customPrompt = ""
    }

    func reset() {
        jellyTask?.cancel()
        jellyTask      = nil
        stage          = .waitingForDrop
        isDragHovering = false
        isDraggingOut  = false
        customPrompt   = ""
        jellyX         = 1.0
        jellyY         = 1.0
    }
}
