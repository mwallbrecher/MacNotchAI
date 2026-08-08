import AppKit
import SwiftUI

/// Presents the two compression sheets.
///
/// Separate windows rather than a SwiftUI `.sheet`: the utilities are triggered from the
/// notch overlay, which is a non-activating floating panel — attaching a modal sheet to it
/// fights the overlay's own sizing/animation. A managed NSWindow is the pattern the rest of
/// the app already uses (Settings, Expose Session), and it inherits the same `.floating + 1`
/// level so it cannot open behind the overlay.
@MainActor
enum CompressPanels {

    private static var imageWindow: NSWindow?
    private static var videoWindow: NSWindow?

    static func showImages(fileURL: URL, sessionFiles: [URL]) {
        let candidates = CompressScan.imageCandidates(allFiles(fileURL, sessionFiles))
        guard candidates.contains(where: \.isEligible) else {
            beep("No images in this session to compress."); return
        }
        imageWindow?.close()
        let view = CompressImagesSheet(candidates: candidates) { imageWindow?.close(); imageWindow = nil }
        imageWindow = present(view, title: "Compress images")
    }

    static func showVideos(fileURL: URL, sessionFiles: [URL]) {
        let candidates = CompressScan.videoCandidates(allFiles(fileURL, sessionFiles))
        guard candidates.contains(where: \.isEligible) else {
            beep("No videos in this session to compress."); return
        }
        videoWindow?.close()
        let view = CompressVideosSheet(candidates: candidates) { videoWindow?.close(); videoWindow = nil }
        videoWindow = present(view, title: "Compress videos")
    }

    /// The primary file first, then the rest of the session, de-duplicated — so the file the
    /// user actually clicked the tool on is the top row.
    private static func allFiles(_ primary: URL, _ session: [URL]) -> [URL] {
        var seen = Set<URL>()
        return ([primary] + session).filter { seen.insert($0).inserted }
    }

    private static func present<V: View>(_ view: V, title: String) -> NSWindow {
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = title
        win.styleMask = [.titled, .closable]
        win.level = .floating + 1      // above the notch overlay (see AppDelegate)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return win
    }

    private static func beep(_ message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
