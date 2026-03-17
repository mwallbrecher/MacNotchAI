import AppKit

class OverlayWindow: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 68),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel          = true
        level                    = .floating
        backgroundColor          = .clear
        isOpaque                 = false
        hasShadow                = true
        isMovableByWindowBackground = false
        collectionBehavior       = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Allow becoming key so text fields inside the panel can receive input.
    // The .nonactivatingPanel style mask still prevents the app from activating,
    // so the user's current app keeps its focus visually.
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Show / hide

    func show() {
        guard !isVisible else { return }
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    func dismissAnimated() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.animator().alphaValue = 0
        }) {
            self.orderOut(nil)
        }
    }

    // MARK: - Positioning

    /// Move + resize the window so its top edge sits flush with the notch.
    /// For Stage 1 the panel is horizontally centered.
    /// For Stage 2/3 the LEFT edge of the left column is pinned to notch-center - 110pt,
    /// so the panel grows to the right as the result column slides in.
    func animateTo(size: CGSize, anchorAtNotchCenter: Bool) {
        guard let screen = NSScreen.main else { return }

        let notchBottomY: CGFloat = 37
        let y = screen.frame.height - notchBottomY - size.height

        let x: CGFloat
        if anchorAtNotchCenter {
            // Left column (220pt wide) centred at notch — panel grows rightward.
            x = (screen.frame.width / 2) - 110
        } else {
            // Pill centred under notch.
            x = (screen.frame.width - size.width) / 2
        }

        let newFrame = NSRect(origin: CGPoint(x: x, y: y), size: size)
        guard frame != newFrame else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0) // spring feel
            ctx.allowsImplicitAnimation = true
            self.animator().setFrame(newFrame, display: true)
        }
    }
}
