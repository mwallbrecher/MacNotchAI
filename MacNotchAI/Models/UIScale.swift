import SwiftUI

// MARK: - UI Scale preference

/// Three discrete size steps for the overlay UI.
/// Each step multiplies every dimension (window, font, padding) by `multiplier`.
/// Medium = 1.2× Small.  Large = 1.2× Medium = 1.44× Small.
enum UIScale: String, CaseIterable {
    case small  = "small"
    case medium = "medium"
    case large  = "large"

    /// Reads the live value from UserDefaults (no Combine overhead — used by
    /// AppDelegate which is outside SwiftUI's environment graph).
    static var current: UIScale {
        UIScale(rawValue: UserDefaults.standard.string(forKey: "uiScale") ?? "") ?? .small
    }

    /// Linear scale factor applied to all window sizes and hardcoded dimensions.
    var multiplier: CGFloat {
        switch self {
        case .small:  return 1.00
        case .medium: return 1.20
        case .large:  return 1.44   // 1.2²
        }
    }

    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }

    var sizeHint: String {
        switch self {
        case .small:  return "Default"
        case .medium: return "+20 %"
        case .large:  return "+44 %"
        }
    }
}

// MARK: - SwiftUI environment key

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Current UI scale multiplier.  Injected by `OverlayView` from `@AppStorage("uiScale")`
    /// so every descendant can read a single, reactive `@Environment(\.uiScale)`.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}
