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

        // mouseUp monitor — fast-path fallback for releases that happen outside
        // the AppKit drag-session modal loop (e.g. user barely moves before releasing).
        //
        // CRITICAL — the pressed-button guard:
        // The callback fires 50 ms after the mouse button is released.  During those
        // 50 ms the user may have already STARTED A NEW DRAG (pressed the button again).
        // Without the guard, handleMouseUp() fires while a new drag is active:
        //   • isDraggingFile = false  →  Combine sink calls hideOverlay()
        //   • stopPolling() snapshots the NEW drag's changeCount into lastDragChangeCount
        //   • Every subsequent handleDrag for the new drag sees count == lastDragChangeCount
        //     → returns early → isDraggingFile never set back to true → pill gone forever
        //
        // NSEvent.pressedMouseButtons bit 0 = left button.  If it is set the user
        // has already pressed the button again — this release belonged to the previous
        // drag, not the current one.  Skip cleanup entirely and let the poll timer or
        // the new drag's own completion path handle teardown.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                    DragMonitor.shared.handleMouseUp()
                }
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

        // Normal case: same pasteboard content as last time — either a continued
        // drag-move event for an already-detected drag, or a plain mouse move with
        // stale pasteboard data from a previous drag.
        guard count != lastDragChangeCount else {
            // Defence-in-depth re-arm:
            // If isDraggingFile was spuriously cleared while this drag session is
            // still live (the pressedMouseButtons guard above now prevents this in
            // most cases, but guard against any other future path), re-detect here.
            // Safe because stopPolling() snapshots the pasteboard changeCount into
            // lastDragChangeCount only when the pasteboard is genuinely empty —
            // so when we reach this branch with isDraggingFile=false AND a file is
            // still on the pasteboard, we know the drag is still active.
            if !isDraggingFile && hasFile(on: pb) && HotkeyManager.shared.isHotkeyHeld() {
                isDraggingFile = true
                startPolling()
            }
            return
        }
        lastDragChangeCount = count

        let hasDrag = hasFile(on: pb)
        if hasDrag, !isDraggingFile {
            // Hotkey gate: if a modifier key is required, only show the pill when
            // it is currently held.  The check runs once per drag session (here,
            // on the first event where changeCount increments).  NSEvent.modifierFlags
            // is the live system-wide modifier state — accurate mid-drag.
            guard HotkeyManager.shared.isHotkeyHeld() else { return }
            isDraggingFile = true
            startPolling()
        } else if !hasDrag {
            isDraggingFile = false
            stopPolling()
        }
    }

    private func handleMouseUp() {
        // Guard: if a successful drop already called dragCompleted() the state is
        // already clean. Firing again would publish a redundant isDraggingFile=false
        // which — during the 0.14 s dismissAnimated window — could race against a
        // freshly created WaitingPillView and its jellyTask. Skip if already idle.
        guard isDraggingFile else { return }
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
