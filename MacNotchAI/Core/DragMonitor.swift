import AppKit
import Combine

/// Watches for file drags anywhere on screen.
/// Only publishes `isDraggingFile`; the actual stage transition (Stage 1 → 2)
/// is handled by DroppableHostingView via NSDraggingDestination.
@MainActor
class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    @Published var isDraggingFile = false

    private var dragMonitor:   Any?
    private var mouseUpMonitor: Any?

    private init() {}

    func startMonitoring() {
        // Global event callbacks already fire on the main thread.
        // Use MainActor.assumeIsolated instead of Task { @MainActor in … }
        // so there is ZERO async hop — the overlay appears on the very same
        // runloop turn as the first drag event, not one cycle later.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            MainActor.assumeIsolated { DragMonitor.shared.handleDrag(event) }
        }

        // 150 ms delay before clearing isDraggingFile on mouseUp.
        // This gives performDragOperation time to fire and change the stage
        // (it fires synchronously before mouseUp) AND gives the user time to
        // start a second drag immediately without the pill disappearing.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { DragMonitor.shared.handleMouseUp() }
            }
        }
    }

    func stopMonitoring() {
        if let m = dragMonitor    { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        dragMonitor    = nil
        mouseUpMonitor = nil
    }

    /// Called by DroppableHostingView immediately after a successful drop.
    func dragCompleted() {
        isDraggingFile = false
    }

    // MARK: - Private

    private func handleDrag(_ event: NSEvent) {
        isDraggingFile = hasFile(on: NSPasteboard(name: .drag))
    }

    private func handleMouseUp() {
        // If the drop was caught (dragCompleted already fired) or a new drag
        // has started (isDraggingFile flipped back to true via handleDrag),
        // AppDelegate.observeDragState guards against a spurious hideOverlay()
        // using the isDraggingFile flag at the time it runs.
        isDraggingFile = false
    }

    private func hasFile(on pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty { return true }

        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !paths.isEmpty { return true }

        return false
    }
}
