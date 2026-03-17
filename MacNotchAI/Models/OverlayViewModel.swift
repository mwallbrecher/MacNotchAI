import Foundation
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
    /// Jelly wobble scale driven by WaitingPillView, applied at OverlayView
    /// level (outside clipShape) so the pill can overflow its layout frame
    /// without being clipped.
    @Published var jellyX: CGFloat = 1.0
    @Published var jellyY: CGFloat = 1.0

    func setChips(url: URL) {
        stage = .chips(url: url, actions: FileInspector.suggestedActions(for: url))
        customPrompt = ""
    }

    func reset() {
        stage          = .waitingForDrop
        isDragHovering = false
        isDraggingOut  = false
        customPrompt   = ""
        jellyX         = 1.0
        jellyY         = 1.0
    }
}
