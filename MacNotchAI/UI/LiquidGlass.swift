import SwiftUI
import AppKit

// MARK: - Backdrop blur

/// NSVisualEffectView wrapper that blurs content BEHIND the window.
/// Works because OverlayWindow has isOpaque=false and backgroundColor=.clear.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = .active
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
    }
}

// MARK: - Glass fill layer

/// Layered background: blur → dark tint → optional colour tint → specular → rim border.
/// `tintOpacity` controls depth: higher = darker = easier to read white text.
/// `colorTint`   overlays a translucent colour (e.g. accentColor on hover) between the
///               dark tint and the specular highlight — at low opacity it adds a subtle
///               hue without washing out the glassy look.
struct LiquidGlassFill: View {
    var cornerRadius: CGFloat
    var tintOpacity: Double = 0.55
    var colorTint: Color    = .clear

    var body: some View {
        ZStack {
            // 1. Backdrop blur — desktop/windows show through, blurred
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            // 2. Deep dark tint — keeps text legible and glass feel subtle
            Color.black.opacity(tintOpacity)

            // 3. Optional colour tint (e.g. system blue on hover) — stays subtle at 0.22
            colorTint.opacity(0.22)

            // 4. Specular highlight — minimal white sheen at the very top
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.11), location: 0.00),
                    .init(color: .white.opacity(0.04), location: 0.45),
                    .init(color: .clear,               location: 1.00),
                ],
                startPoint: .top, endPoint: .bottom
            )

            // 5. Rim border — bright top-leading, fades bottom-trailing
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.40), location: 0.00),
                            .init(color: .white.opacity(0.12), location: 0.50),
                            .init(color: .white.opacity(0.03), location: 1.00),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Convenience modifiers

extension View {
    /// Full liquid-glass background: backdrop blur + deep dark tint + optional colour tint + specular + rim.
    func liquidGlass(cornerRadius: CGFloat,
                     tintOpacity: Double = 0.55,
                     colorTint: Color = .clear) -> some View {
        self
            .background(LiquidGlassFill(cornerRadius: cornerRadius,
                                         tintOpacity: tintOpacity,
                                         colorTint: colorTint))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Liquid glass for circular shapes (close/share buttons).
    func liquidGlassCircle(tintOpacity: Double = 0.50,
                            colorTint: Color = .clear) -> some View {
        self
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    Color.black.opacity(tintOpacity)
                    colorTint.opacity(0.22)
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.11), location: 0.0),
                            .init(color: .clear,               location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.38), .white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
                .clipShape(Circle())
            )
            .clipShape(Circle())
    }

    /// Liquid glass for capsule shapes (chips, handoff button).
    func liquidGlassCapsule(tintOpacity: Double = 0.45,
                             colorTint: Color = .clear) -> some View {
        self
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    Color.black.opacity(tintOpacity)
                    colorTint.opacity(0.22)
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.10), location: 0.0),
                            .init(color: .clear,               location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .white.opacity(0.04)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
                .clipShape(Capsule(style: .continuous))
            )
            .clipShape(Capsule(style: .continuous))
    }
}
