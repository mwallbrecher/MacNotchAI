import AppKit
import Combine

/// Watches for file drags anywhere on screen.
/// Only publishes `isDraggingFile`; the actual stage transition (Stage 1 → 2)
/// is now handled by DroppableHostingView via NSDraggingDestination,
/// so there is no more "near top" heuristic.
@MainActor
class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    @Published var isDraggingFile = false

    private var dragMonitor:  Any?
    private var mouseUpMonitor: Any?

    private init() {}

    func startMonitoring() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            Task { @MainActor in DragMonitor.shared.handleDrag(event) }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                Task { @MainActor in DragMonitor.shared.handleMouseUp() }
            }
        }
    }

    func stopMonitoring() {
        if let m = dragMonitor    { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        dragMonitor    = nil
        mouseUpMonitor = nil
    }

    /// Called by DroppableHostingView after a successful drop so the pill
    /// disappears immediately without waiting for the mouseUp event.
    func dragCompleted() {
        isDraggingFile = false
    }

    // MARK: - Private

    private func handleDrag(_ event: NSEvent) {
        isDraggingFile = hasFile(on: NSPasteboard(name: .drag))
    }

    private func handleMouseUp() {
        // If the file was dropped on our view, dragCompleted() already cleared
        // isDraggingFile.  If the user dropped elsewhere, clear it now.
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
