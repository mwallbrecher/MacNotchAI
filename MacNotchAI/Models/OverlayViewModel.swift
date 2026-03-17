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
    }

    @Published var stage: Stage = .waitingForDrop
    /// Text typed into the custom-prompt field in the result column.
    @Published var customPrompt: String = ""

    func setChips(url: URL) {
        stage = .chips(url: url, actions: FileInspector.suggestedActions(for: url))
        customPrompt = ""
    }

    func reset() {
        stage = .waitingForDrop
        customPrompt = ""
    }
}
