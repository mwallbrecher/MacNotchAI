import AppKit

// THESIS (L1 sensor) — frontmost-application changes via NSWorkspace notifications.
// Ungated, event-driven, effectively free. The app-switch sequence is the backbone
// of the M2 detectors `copy_then_translator_switch` and `collect_mode` (sources).
final class AppFocusSensor: IntentSensor {

    let name = "appFocus"

    private weak var bus: SignalBus?
    private var observer: NSObjectProtocol?
    private var current: (bundleID: String, appName: String, since: TimeInterval)?
    private var isSuspended = true
    private let prepareForActivation: ((String) -> Void)?

    init(prepareForActivation: ((String) -> Void)? = nil) {
        self.prepareForActivation = prepareForActivation
    }

    func start(bus: SignalBus) {
        self.bus = bus
        resume()
    }

    func startSuspended(bus: SignalBus) {
        self.bus = bus
        isSuspended = true
        current = nil
    }

    func stop() {
        suspend()
        bus = nil
    }

    /// App-focus notifications are event-driven, but a participant pause is a capture
    /// boundary, not merely an energy hint. Remove the observer and discard the
    /// baseline so neither a switch during the gap nor the gap's duration leaks into
    /// the first post-resume event.
    func suspend() {
        isSuspended = true
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        current = nil
    }

    /// Close the current app segment before pause/sleep/inactivity/stop. This record
    /// is denominator/context metadata; FeatureExtractor deliberately ignores it.
    func flushBeforeGap() {
        guard !isSuspended, let current else { return }
        let now = MonotonicClock.now
        bus?.publish(.live(kind: .appFocus, appFocus: AppFocusPayload(
            bundleID: current.bundleID,
            appName: current.appName,
            category: Self.category(for: current.bundleID),
            previousBundleID: current.bundleID,
            secondsInPrevious: ((now - current.since) * 10).rounded() / 10,
            transition: "segment_end")))
    }

    func resume() {
        guard isSuspended, bus != nil else { return }
        isSuspended = false
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            let appName = app.localizedName ?? bundleID
            current = (bundleID, appName, MonotonicClock.now)
            bus?.publish(.live(kind: .appFocus, appFocus: AppFocusPayload(
                bundleID: bundleID, appName: appName,
                category: Self.category(for: bundleID),
                previousBundleID: nil, secondsInPrevious: nil,
                transition: "baseline")))
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.handleActivation(app)
        }
    }

    private func handleActivation(_ app: NSRunningApplication) {
        guard !isSuspended else { return }
        guard let bundleID = app.bundleIdentifier else { return }
        guard bundleID != current?.bundleID else { return }   // spurious re-activation

        // Clipboard reconciliation and dwell closure must happen before this focus
        // row reaches FeatureExtractor. A single observer owns all three operations,
        // so rapid copy→switch detection no longer depends on unspecified observer
        // callback ordering in NSWorkspace's notification center.
        prepareForActivation?(bundleID)

        let t = MonotonicClock.now
        let previous = current
        let appName = app.localizedName ?? bundleID
        current = (bundleID, appName, t)

        bus?.publish(.live(kind: .appFocus, appFocus: AppFocusPayload(
            bundleID: bundleID,
            appName: appName,
            category: Self.category(for: bundleID),
            previousBundleID: previous?.bundleID,
            secondsInPrevious: previous.map { ((t - $0.since) * 10).rounded() / 10 },
            transition: "activated")))
    }

    // MARK: Coarse app categories
    //
    // Deliberately coarse: the scorer needs "switched toward a translator-ish thing",
    // not an app census. Unknowns fall through keyword heuristics to "other".
    // Translator *websites* (deepl.com in a browser tab) need the window title — AX, M2.

    private static let knownCategories: [String: String] = [
        // browsers
        "com.apple.Safari": "browser", "com.google.Chrome": "browser",
        "org.mozilla.firefox": "browser", "com.microsoft.edgemac": "browser",
        "company.thebrowser.Browser": "browser", "com.brave.Browser": "browser",
        // translators / dictionaries
        "com.linguee.DeepLCopyTranslator": "translator", "com.deepl.macos": "translator",
        // documents & reading
        "com.apple.Preview": "pdf", "com.apple.iBooksX": "pdf",
        "com.apple.Notes": "notes", "com.apple.TextEdit": "editor",
        "com.apple.iWork.Pages": "editor", "com.microsoft.Word": "editor",
        "md.obsidian": "notes", "notion.id": "notes",
        // mail & messaging
        "com.apple.mail": "mail", "com.microsoft.Outlook": "mail",
        "com.tinyspeck.slackmacgap": "messaging", "net.whatsapp.WhatsApp": "messaging",
        // dev
        "com.apple.dt.Xcode": "ide", "com.microsoft.VSCode": "ide",
        "com.apple.Terminal": "terminal", "com.googlecode.iterm2": "terminal",
        // spreadsheets
        "com.apple.iWork.Numbers": "spreadsheet", "com.microsoft.Excel": "spreadsheet",
    ]

    static func category(for bundleID: String) -> String {
        if let known = knownCategories[bundleID] { return known }
        let lower = bundleID.lowercased()
        if lower.contains("mail") { return "mail" }
        if lower.contains("translat") || lower.contains("dict") { return "translator" }
        if lower.contains("browser") { return "browser" }
        if lower.contains("pdf") { return "pdf" }
        if lower.contains("note") { return "notes" }
        return "other"
    }
}
