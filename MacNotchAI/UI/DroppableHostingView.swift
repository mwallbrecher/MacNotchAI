import AppKit
import SwiftUI

/// NSHostingView subclass that acts as an NSDraggingDestination.
/// In Stage 1 (waitingForDrop) it accepts file drops and transitions
/// the overlay to Stage 2. In any other stage it ignores drags so a
/// result already on screen isn't accidentally replaced.
final class DroppableHostingView<Content: View>: NSHostingView<Content> {

    required override init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .waitingForDrop = OverlayViewModel.shared.stage,
              extractURL(from: sender.draggingPasteboard) != nil else { return [] }
        OverlayViewModel.shared.isDragHovering = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .waitingForDrop = OverlayViewModel.shared.stage,
              extractURL(from: sender.draggingPasteboard) != nil else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        OverlayViewModel.shared.isDragHovering = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = extractURL(from: sender.draggingPasteboard) else { return false }
        OverlayViewModel.shared.isDragHovering = false
        OverlayViewModel.shared.setChips(url: url)
        // Tell DragMonitor the drag is finished so the pill-show logic
        // doesn't re-trigger while the user is still physically releasing.
        DragMonitor.shared.dragCompleted()
        return true
    }

    // MARK: - Helper

    private func extractURL(from pasteboard: NSPasteboard) -> URL? {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first
    }
}

