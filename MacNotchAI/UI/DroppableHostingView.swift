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

    /// Returning false prevents excessive timer-based draggingUpdated calls.
    /// Movement-based calls (cursor moves within the view) still fire — sufficient
    /// to update the hover state as the cursor crosses the pill boundary.
    var wantsPeriodicDraggingUpdates: Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard extractURL(from: sender.draggingPasteboard) != nil else { return [] }
        // Hover only when cursor is actually over the visible pill, not the transparent
        // canvas that surrounds it. The window is 288×96 but the pill is only 240×68
        // pinned to the top — the 28pt strip below the pill is transparent dead space.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard extractURL(from: sender.draggingPasteboard) != nil else { return [] }
        // Re-evaluate hover as the cursor moves within the window so the jelly fires
        // exactly when the cursor crosses into the pill, not into the canvas border.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        OverlayViewModel.shared.isDragHovering = false
    }

    /// Must return true for performDragOperation to be called.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Clear hover and signal drag-end UNCONDITIONALLY here — the user released
        // the mouse button so the drag session is over regardless of whether we
        // accept the payload. Calling dragCompleted() before the guard prevents
        // the poll timer from running past this point and avoids the race where a
        // failed guard (stale pasteboard, wrong stage) leaves the timer alive,
        // which then fires hideOverlay() while a new jellyTask is mid-flight.
        OverlayViewModel.shared.isDragHovering = false
        DragMonitor.shared.dragCompleted()

        guard case .waitingForDrop = OverlayViewModel.shared.stage,
              let url = extractURL(from: sender.draggingPasteboard) else { return false }

        // Animate chips column in with a spring — the transition IS the catch feedback.
        withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
            OverlayViewModel.shared.setChips(url: url)
        }
        return true
    }

    // MARK: - Pill hit-test helper

    /// Returns true if the drag cursor is over the visible pill area.
    ///
    /// In stage 1 the window canvas is 288×96 but the pill is 240×68 pinned to the
    /// top — the bottom 28pt strip is transparent. Without this check `isDragHovering`
    /// would fire for the transparent zone, triggering the jelly wobble while the cursor
    /// appears to be hovering BELOW the pill. In stages 2/3 the whole card is the target
    /// so we return true unconditionally.
    private func isOverPillArea(_ sender: NSDraggingInfo) -> Bool {
        guard case .waitingForDrop = OverlayViewModel.shared.stage else { return true }
        // draggingLocation is in the window's base coordinate system.
        // convert(_:from:nil) maps that to the view's own coordinate space.
        let loc = convert(sender.draggingLocation, from: nil)
        // Pill: 240 pt wide centred in 288 pt (24 pt margins each side),
        //       68 pt tall pinned to the top of the 96 pt canvas.
        // AppKit y=0 is at the BOTTOM, so the pill's bottom edge sits at
        //   bounds.height − 68  (= 28 pt up from the window bottom).
        let pillRect = NSRect(x: 24, y: max(0, bounds.height - 68), width: 240, height: 68)
        return pillRect.contains(loc)
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
