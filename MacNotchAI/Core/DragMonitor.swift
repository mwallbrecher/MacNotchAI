import AppKit
import Combine

/// Watches for file drags anywhere on screen.
/// Only publishes `isDraggingFile`; the actual stage transition (Stage 1 → 2)
/// is handled by DroppableHostingView via NSDraggingDestination.
@MainActor
class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    @Published var isDraggingFile = false

    private var dragMonitor:    Any?
    private var mouseUpMonitor: Any?

    // ── Drag-end polling ─────────────────────────────────────────────────────
    // NSEvent.addGlobalMonitorForEvents(.leftMouseUp) is NOT delivered during
    // an active AppKit drag session because macOS runs the drag in the special
    // .eventTracking runloop mode which silences .default-mode global monitors.
    // A Timer added to .common mode fires in EVERY mode (default, eventTracking,
    // modalPanel) and polls the drag pasteboard — when it empties the drag ended.
    private var pollTimer: Timer?

    // ── Stale-pasteboard guard ────────────────────────────────────────────────
    // NSPasteboard(name: .drag) retains its content between drag sessions.
    // Any leftMouseDragged (even with no file) would find the old file URLs and
    // falsely trigger the pill.  We only react when the changeCount increments —
    // which happens exactly once per new drag session (when the source app writes
    // fresh items to the drag pasteboard).
    private var lastDragChangeCount: Int = NSPasteboard(name: .drag).changeCount

    private init() {}

    func startMonitoring() {
        // Global drag callbacks already fire on the main thread.
        // MainActor.assumeIsolated gives ZERO async hop — pill appears on the
        // very same runloop turn as the first drag event.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            MainActor.assumeIsolated { DragMonitor.shared.handleDrag(event) }
        }

        // mouseUp monitor kept as a fast-path fallback for non-drag-session
        // mouse releases (e.g. user clicks and barely moves).
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
        stopPolling()
    }

    /// Called by DroppableHostingView immediately after a successful drop.
    func dragCompleted() {
        isDraggingFile = false
        stopPolling()
    }

    // MARK: - Private – event handlers

    private func handleDrag(_ event: NSEvent) {
        let pb    = NSPasteboard(name: .drag)
        let count = pb.changeCount

        // Skip events where the pasteboard hasn't changed — these are either
        // continued drag-move events for an already-detected drag (isDraggingFile
        // is already true, polling handles cleanup) or plain mouse moves after a
        // previous drag whose stale contents are still in the pasteboard.
        guard count != lastDragChangeCount else { return }
        lastDragChangeCount = count

        let hasDrag = hasFile(on: pb)
        if hasDrag, !isDraggingFile {
            isDraggingFile = true
            startPolling()
        } else if !hasDrag {
            isDraggingFile = false
            stopPolling()
        }
    }

    private func handleMouseUp() {
        isDraggingFile = false
        stopPolling()
    }

    // MARK: - Private – drag-end polling

    /// Starts a timer that fires in .common runloop mode (works even inside
    /// AppKit's .eventTracking modal drag loop) and clears isDraggingFile
    /// the moment the drag pasteboard empties.
    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer fires on the main runloop; MainActor.assumeIsolated is safe.
            MainActor.assumeIsolated {
                if !self.hasFile(on: NSPasteboard(name: .drag)) {
                    self.isDraggingFile = false
                    self.stopPolling()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)   // .common = fires in ALL modes
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Snapshot the current changeCount so the next identical pasteboard state
        // (stale data from this drag) doesn't re-trigger handleDrag.
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    }

    // MARK: - Private – pasteboard inspection

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
