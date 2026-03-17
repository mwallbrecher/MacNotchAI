import AppKit
import Combine

@MainActor
class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    @Published var isDraggingNearTop = false
    @Published var draggedFileURL: URL? = nil

    private var eventMonitor: Any?
    private var mouseUpMonitor: Any?

    // Top 12% of screen triggers the overlay
    private let triggerZoneRatio: CGFloat = 0.12

    private init() {}

    func startMonitoring() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged]
        ) { event in
            Task { @MainActor in
                DragMonitor.shared.handleDragEvent(event)
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { _ in
            Task { @MainActor in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    DragMonitor.shared.handleMouseUp()
                }
            }
        }
    }

    func stopMonitoring() {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseUpMonitor { NSEvent.removeMonitor(monitor) }
        eventMonitor = nil
        mouseUpMonitor = nil
    }

    private func handleDragEvent(_ event: NSEvent) {
        guard let screen = NSScreen.main else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screenHeight = screen.frame.height
        let triggerY = screenHeight * (1 - triggerZoneRatio)

        let isNearTop = mouseLocation.y > triggerY

        let dragPasteboard = NSPasteboard(name: .drag)
        let fileURL = extractFileURL(from: dragPasteboard)

        draggedFileURL = fileURL
        isDraggingNearTop = isNearTop && fileURL != nil
    }

    private func handleMouseUp() {
        if !isDraggingNearTop {
            draggedFileURL = nil
        }
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
