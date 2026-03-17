import AppKit
import SwiftUI

/// NSHostingView subclass that acts as an NSDraggingDestination.
/// Drop detection is intentionally permissive — we always return .copy
/// for valid file URLs and guard the actual state transition in
/// performDragOperation. This prevents missed drops due to timing races.
final class DroppableHostingView<Content: View>: NSHostingView<Content> {

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Register all file drag flavours — modern + legacy fallback
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.file-url"),
        ])
        // Transparent layer — prevents gray/white flash before SwiftUI paints
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        layer?.borderWidth     = 0
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - NSDraggingDestination

    /// Returning false prevents excessive draggingUpdated calls — not needed.
    var wantsPeriodicDraggingUpdates: Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard extractURL(from: sender.draggingPasteboard) != nil else { return [] }
        // Set hover regardless of stage — performDragOperation guards the actual transition.
        // This prevents false negatives when the window shows mid-drag.
        OverlayViewModel.shared.isDragHovering = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard extractURL(from: sender.draggingPasteboard) != nil else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        OverlayViewModel.shared.isDragHovering = false
    }

    /// Must return true for performDragOperation to be called.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        OverlayViewModel.shared.isDragHovering = false
        guard case .waitingForDrop = OverlayViewModel.shared.stage,
              let url = extractURL(from: sender.draggingPasteboard) else { return false }

        // Animate chips column in with a spring — the transition IS the catch feedback.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
            OverlayViewModel.shared.setChips(url: url)
        }
        DragMonitor.shared.dragCompleted()
        return true
    }

    // MARK: - Helper

    private func extractURL(from pasteboard: NSPasteboard) -> URL? {
        // Primary: modern fileURL type
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let first = urls.first {
            return first
        }
        // Fallback: legacy NSFilenamesPboardType (older apps, Finder on some OS versions)
        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], let path = paths.first {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
