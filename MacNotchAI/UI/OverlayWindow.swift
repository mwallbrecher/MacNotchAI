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
        hasShadow                   = false
        isMovableByWindowBackground = false
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Show / hide

    func show() {
        guard !isVisible else { return }
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
            self.alphaValue = 1
        }
    }

    // MARK: - Positioning

    /// Place the window at the correct notch position instantly — call BEFORE show().
    func place(size: CGSize, anchorAtNotchCenter: Bool) {
        setFrame(notchFrame(for: size, anchorAtNotchCenter: anchorAtNotchCenter), display: false)
    }

    /// Resize and reposition the window instantly.
    ///
    /// We intentionally do NOT use NSAnimationContext / animator().setFrame() here.
    /// The animated proxy drives the window frame through intermediate sizes at 60 fps;
    /// AppKit runs a full constraint-solving layout pass on each intermediate frame.
    /// When those intermediate sizes are inconsistent with the NSHostingView's fixed-width
    /// SwiftUI subviews the solver cannot converge → recursive "Update Constraints in
    /// Window" → abort().  All visual animation is handled by SwiftUI transitions and
    /// spring modifiers inside the content view, so the instant frame change is invisible
    /// to the user — they only see the black content shape morphing smoothly.
    func animateTo(size: CGSize, anchorAtNotchCenter: Bool) {
        let newFrame = notchFrame(for: size, anchorAtNotchCenter: anchorAtNotchCenter)
        guard frame != newFrame else { return }
        setFrame(newFrame, display: true)
    }

    // MARK: - Private helpers

    private func notchFrame(for size: CGSize, anchorAtNotchCenter: Bool) -> NSRect {
        guard let screen = NSScreen.main else { return frame }
        let notchBottomY: CGFloat = 37
        let y = screen.frame.height - notchBottomY - size.height
        let x: CGFloat = anchorAtNotchCenter
            ? (screen.frame.width / 2) - 110
            : (screen.frame.width - size.width) / 2
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
