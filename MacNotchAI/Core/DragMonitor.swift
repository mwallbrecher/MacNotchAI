import AppKit
import Combine

@MainActor
class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    /// True as soon as ANY file drag is detected anywhere on screen (drives Stage 1 pill).
    @Published var isDraggingFile = false
    /// True only when the drag is inside the top 12% trigger zone.
    @Published var isDraggingNearTop = false
    /// Set when a file is released while inside the trigger zone (drives Stage 2 chips).
    @Published var draggedFileURL: URL? = nil

    private var eventMonitor: Any?
    private var mouseUpMonitor: Any?
    private let triggerZoneRatio: CGFloat = 0.12

    private init() {}

    func startMonitoring() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            Task { @MainActor in DragMonitor.shared.handleDragEvent(event) }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            // Small delay so the drop can register on the pasteboard first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Task { @MainActor in DragMonitor.shared.handleMouseUp() }
            }
        }
    }

    func stopMonitoring() {
        if let m = eventMonitor  { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor { NSEvent.removeMonitor(m) }
        eventMonitor  = nil
        mouseUpMonitor = nil
    }

    private func handleDragEvent(_ event: NSEvent) {
        let dragPasteboard = NSPasteboard(name: .drag)
        guard let fileURL = extractFileURL(from: dragPasteboard) else {
            // Not a file drag — ignore
            isDraggingFile    = false
            isDraggingNearTop = false
            return
        }

        isDraggingFile = true

        guard let screen = NSScreen.main else { return }
        let triggerY   = screen.frame.height * (1 - triggerZoneRatio)
        let isNearTop  = NSEvent.mouseLocation.y > triggerY
        isDraggingNearTop = isNearTop

        // Pre-cache the URL so it's available at mouseUp time.
        if isNearTop { draggedFileURL = fileURL }
    }

    private func handleMouseUp() {
        // If the drag ended outside the trigger zone, clear any cached URL.
        if !isDraggingNearTop { draggedFileURL = nil }
        isDraggingFile    = false
        isDraggingNearTop = false
    }

    private func extractFileURL(from pasteboard: NSPasteboard) -> URL? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let first = urls.first {
            return first
        }
        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], let first = paths.first {
            return URL(fileURLWithPath: first)
        }
        return nil
    }
}
