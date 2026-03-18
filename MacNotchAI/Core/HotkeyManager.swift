import AppKit

/// Stores and checks the optional modifier-key hotkey that gates pill appearance.
///
/// When a hotkey is set the pill only appears when the user holds the required
/// modifier combination while starting a drag.  When no hotkey is set (raw value 0)
/// every drag shows the pill normally.
final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    private let defaultsKey = "hotkeyModifierFlags"

    // MARK: - Storage

    /// The required modifier flags.  Empty set = no hotkey configured.
    var requiredModifiers: NSEvent.ModifierFlags {
        get {
            let raw = UInt(bitPattern: UserDefaults.standard.integer(forKey: defaultsKey))
            return NSEvent.ModifierFlags(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(Int(bitPattern: newValue.rawValue), forKey: defaultsKey)
        }
    }

    /// True when a hotkey is configured (at least one modifier is required).
    var isEnabled: Bool { !requiredModifiers.isEmpty }

    // MARK: - Display

    /// Human-readable symbol string for the current hotkey, e.g. "⌥⌘".
    var displayString: String {
        Self.displayString(for: requiredModifiers)
    }

    /// Human-readable symbol string for an arbitrary modifier set.
    static func displayString(for flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.isEmpty ? "None" : parts.joined()
    }

    // MARK: - Runtime check

    /// Returns true when the hotkey constraint is satisfied.
    ///
    /// If no hotkey is configured this always returns true (pill works normally).
    /// Otherwise it reads `NSEvent.modifierFlags` — the live modifier state — and
    /// checks that every required modifier is currently held.
    func isHotkeyHeld() -> Bool {
        guard isEnabled else { return true }
        let current = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return current.contains(requiredModifiers)
    }

    // MARK: - Mutation

    func clear() { requiredModifiers = [] }
}
