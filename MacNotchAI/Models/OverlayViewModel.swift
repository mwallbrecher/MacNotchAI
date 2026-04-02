import SwiftUI
import Combine

/// Shared state that drives which stage the overlay is in.
/// AppDelegate writes to it; OverlayView reads from it.
@MainActor
class OverlayViewModel: ObservableObject {
    static let shared = OverlayViewModel()

    // Persisted UI preference keys
    private static let keyChipsExpanded     = "pref.chipsExpanded"
    private static let keyFollowupsExpanded = "pref.followupsExpanded"

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // ── Restore persisted UI preferences from the previous session ────────
        // This means collapsing chips or follow-ups carries over between drops.
        if let saved = UserDefaults.standard.object(forKey: Self.keyChipsExpanded) as? Bool {
            isChipsExpanded = saved
        }
        if let saved = UserDefaults.standard.object(forKey: Self.keyFollowupsExpanded) as? Bool {
            isFollowupsExpanded = saved
        }

        // ── Persist changes automatically ─────────────────────────────────────
        // dropFirst() skips the initial value that Combine emits on subscription
        // so we don't write UserDefaults unnecessarily at startup.
        $isChipsExpanded
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: Self.keyChipsExpanded) }
            .store(in: &cancellables)

        $isFollowupsExpanded
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: Self.keyFollowupsExpanded) }
            .store(in: &cancellables)
    }

    enum Stage {
        case waitingForDrop
        case chips(url: URL, actions: [AIAction])
        case loading(url: URL, action: AIAction)
        case result(url: URL, action: AIAction, text: String)
        case error(url: URL, message: String)

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

        /// Integer tag used as SwiftUI animation value when stage changes.
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
    @Published var isDragHovering = false
    @Published var isDraggingOut  = false
    @Published var customPrompt: String = ""

    // Last AI result snapshot — saved when the user taps ← back so they can
    // restore it via → without re-running the AI call. Cleared on fresh drop,
    // new action start, or full reset.
    @Published var cachedResult: Stage? = nil
    // Drives the "Session opened in …" confirmation pill in stage 2.
    // Set after handoff navigation, auto-cleared after 6 s.
    @Published var handoffProviderName: String? = nil

    /// URL of a second file dropped while an active session is running.
    /// Shown as a banner prompt: "Add to session" or "New session".
    /// Cleared when the user picks an option or dismisses.
    @Published var pendingSecondFileURL: URL? = nil

    /// Files added to the current session via "Add to session".
    /// Their content is concatenated with the primary file's content in AI calls.
    /// Cleared on reset() and setChips() (fresh session).
    @Published var additionalFileURLs: [URL] = []

    // ── Jelly wobble ─────────────────────────────────────────────────────────
    // Applied to the pill scaleEffect in OverlayView (outside clipShape so it
    // overflows into the transparent canvas without hitting NSHostingView clip).
    // IMPORTANT: NSView bounds are NOT changed by SwiftUI scaleEffect — the
    // drag hitbox is always the full 288×96 canvas, regardless of visual scale.
    @Published var jellyX: CGFloat = 1.0
    @Published var jellyY: CGFloat = 1.0

    // ── Collapse / entry gate ─────────────────────────────────────────────────
    // OverlayView combines this with its local `appeared` Bool to compute
    // `isAtFullScale`. Setting isCollapsing = true plays the spring in reverse
    // (Y: 1.0 → 0.02, squishing back into the notch). reset() clears it so the
    // next entry (or reuse) plays the pop-in spring again.
    @Published var isCollapsing:        Bool = false
    @Published var isChipsExpanded:     Bool = true     // overwritten by init() from UserDefaults
    @Published var isFollowupsExpanded: Bool = false    // overwritten by init() from UserDefaults

    // MARK: - Jelly
    //
    // Design rule: ONE withAnimation call per method, called directly on the main
    // thread. No Tasks, no sleep-based timing, no multi-phase choreography.
    // The spring's own damping ratio produces the wobble naturally — if damping < 1
    // the spring overshoots and oscillates to rest, which IS the wobble effect.
    // This eliminates the entire class of "two concurrent withAnimation on the same
    // binding" crashes that multi-Task approaches produce.

    func startJellyHover() {
        // Overdamped enough to reach 1.12 cleanly without oscillating past it.
        withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
            jellyX = 1.12; jellyY = 1.12
        }
    }

    func stopJellyHover() {
        // Low damping fraction → spring overshoots 1.0 and oscillates briefly.
        // That oscillation is the wobble. No manual phase timing needed.
        withAnimation(.spring(response: 0.30, dampingFraction: 0.44)) {
            jellyX = 1.0; jellyY = 1.0
        }
    }

    // MARK: - State

    func setChips(url: URL) {
        additionalFileURLs = []   // fresh drop clears any previously added files
        // Fresh drop — previous session's cached result no longer relevant.
        cachedResult = nil
        stage = .chips(url: url, actions: FileInspector.suggestedActions(for: url))
        customPrompt = ""
    }

    /// Navigate back to the chips stage while keeping the current result cached
    /// so the user can tap → to restore it without re-running the AI.
    func navigateBackToChips(savingResult result: Stage, url: URL) {
        cachedResult = result
        stage = .chips(url: url, actions: FileInspector.suggestedActions(for: url))
        customPrompt = ""
    }

    /// Partial reset: clears transient interaction flags without touching `stage`.
    /// Called at the START of hideOverlay() so the fade animation plays over the
    /// current stage's UI — not over a prematurely-switched WaitingPillView.
    func partialReset() {
        isDragHovering      = false
        isDraggingOut       = false
        handoffProviderName = nil
        pendingSecondFileURL = nil
        jellyX              = 1.0
        jellyY              = 1.0
    }

    /// Full state reset. Called once the dismiss animation completes (window hidden)
    /// or when a fading window is recycled by ensureOverlayVisible().
    /// Restores isChipsExpanded / isFollowupsExpanded from the persisted preference
    /// so the next session starts in the state the user left it.
    func reset() {
        stage         = .waitingForDrop
        isDragHovering = false
        isDraggingOut  = false
        customPrompt   = ""
        cachedResult        = nil
        handoffProviderName = nil
        pendingSecondFileURL  = nil
        additionalFileURLs    = []
        jellyX              = 1.0
        jellyY         = 1.0
        isCollapsing   = false
        // Restore saved preferences so each new session matches the last one.
        isChipsExpanded     = UserDefaults.standard.object(forKey: Self.keyChipsExpanded)     as? Bool ?? true
        isFollowupsExpanded = UserDefaults.standard.object(forKey: Self.keyFollowupsExpanded) as? Bool ?? false
    }
}
