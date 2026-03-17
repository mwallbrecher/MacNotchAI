import AppKit

class OverlayWindow: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        // The SwiftUI view provides the black background and corner radius.
        // Keeping the window itself clear lets the shadow render correctly.
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // CRITICAL: do not steal keyboard focus from the user's current app
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenWidth = screen.frame.width
        let screenHeight = screen.frame.height

        // Flush the top edge of the panel with the bottom of the notch (~37pt).
        // On Macs without a notch this still anchors sensibly near the top.
        let notchBottomY: CGFloat = 37
        let panelTopY = screenHeight - notchBottomY
        let x = (screenWidth - frame.width) / 2
        let y = panelTopY - frame.height // panel hangs downward from notch

        setFrameOrigin(NSPoint(x: x, y: y))

        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func dismissAnimated() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            self.animator().alphaValue = 0
        }) {
            self.orderOut(nil)
        }
    }
}
