import AppKit

class OverlayWindow: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 68),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel             = true
        level                       = .floating
        backgroundColor             = .clear
        isOpaque                    = false
        hasShadow                   = false          // All shadow via SwiftUI; avoids NSPanel chrome ring
        isMovableByWindowBackground = false
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Show / hide

    func show() {
        guard !isVisible else { return }
        // SwiftUI entry animation starts from scale(y:~0), no need for alpha fade here.
        alphaValue = 1
        orderFront(nil)
    }

    func dismissAnimated() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }) {
            self.orderOut(nil)
            self.alphaValue = 1   // reset for next show
        }
    }

    // MARK: - Positioning

    /// Moves + resizes the window instantly (no animation).
    /// Call this BEFORE show() so the window is never visible at screen origin.
    func place(size: CGSize, anchorAtNotchCenter: Bool) {
        guard let screen = NSScreen.main else { return }
        let notchBottomY: CGFloat = 37
        let y = screen.frame.height - notchBottomY - size.height
        let x: CGFloat = anchorAtNotchCenter
            ? (screen.frame.width / 2) - 110
            : (screen.frame.width - size.width) / 2
        setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: false)
    }

    /// Animates to a new size/position.  Used for stage transitions after the window is visible.
    func animateTo(size: CGSize, anchorAtNotchCenter: Bool) {
        guard let screen = NSScreen.main else { return }

        let notchBottomY: CGFloat = 37
        let y = screen.frame.height - notchBottomY - size.height

        let x: CGFloat = anchorAtNotchCenter
            ? (screen.frame.width / 2) - 110
            : (screen.frame.width - size.width) / 2

        let newFrame = NSRect(origin: CGPoint(x: x, y: y), size: size)
        guard frame != newFrame else { return }

        // Spring-feel cubic bezier — slight overshoot on expansion.
        // IMPORTANT: do NOT use a bezier with a y-control-point > 1.0 (e.g. 1.56).
        // An overshoot timing function drives the frame through an intermediate size
        // larger than the target.  AppKit's constraint solver re-enters layout for
        // every intermediate frame; when the frame briefly exceeds the target the
        // solver loops → "Update Constraints in Window" assertion → abort().
        // easeOut gives a fast start / smooth settle that still feels snappy.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }
}
