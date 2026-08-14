import AppKit
import ApplicationServices

// THESIS (L1 sensor, M2) — text selection + focused-window context via the
// Accessibility API. THE ONLY permission-gated sensor in the pipeline.
//
// AX reads are synchronous cross-process IPC. They run on one serial utility queue,
// with a 0.5 s timeout on every element, while the main thread only schedules and
// publishes the classified result. Adaptive 1 → 3 s polling bounds energy cost.
//
// Pause/sleep correctness needs more than invalidating the timer: an AX request may
// already be blocked in another process. Every dispatch therefore carries a lifecycle
// generation. Suspending increments the generation; a late completion from an older
// generation is discarded before it can publish or re-arm backoff state.
final class SelectionSensor: IntentSensor {

    let name = "selection"

    private weak var bus: SignalBus?
    private var timer: Timer?
    private var lastSelectionHash = ""
    private var lastSelectionDocID: String?
    private var lastTranslatorContext = false
    private var isSuspended = true

    /// AX work happens here, never on main. Serial: one request at a time.
    private let axQueue = DispatchQueue(label: "com.aidrop.intent.ax", qos: .utility)
    private var pollInFlight = false
    private var generation: UInt64 = 0

    // Adaptive backoff (fast while things change, slow while they do not).
    private let fastInterval: TimeInterval = 1.0
    private let slowInterval: TimeInterval = 3.0
    private let backoffAfterIdlePolls = 10
    private var unchangedPolls = 0
    private var currentInterval: TimeInterval = 1.0
    private var activityObservers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?

    /// The grant can be removed while the process is running. IntentEngine records
    /// that coverage boundary and removes this sensor instead of silently polling an
    /// API that can no longer return evidence.
    var onTrustLost: (() -> Void)?

    private static let translatorMarkers = [
        "deepl", "translate", "translator", "linguee", "dict.cc", "leo.org",
        "reverso", "übersetzer", "wörterbuch", "dictionary",
    ]

    private struct PollResult {
        /// PID read from the AX element itself. This prevents a fast app switch from
        /// labelling text from app B with the frontmost-app snapshot of app A.
        let pid: pid_t?
        let docID: String?
        let translator: Bool
        /// Classified off-main; `app` is filled from `pid` on completion.
        let selection: SelectionPayload?
    }

    func start(bus: SignalBus) {
        self.bus = bus
        resume()
    }

    func stop() {
        suspend()
        bus = nil
    }

    /// Invalidates all queued results as well as every main-runloop trigger. The AX
    /// call itself cannot be cancelled, but its result can never cross this boundary.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        generation &+= 1
        timer?.invalidate()
        timer = nil
        removeActivityObservers()
        unchangedPolls = 0
        currentInterval = fastInterval
        lastSelectionHash = ""
        lastSelectionDocID = nil
        lastTranslatorContext = false
    }

    func resume() {
        guard isSuspended, bus != nil, AXIsProcessTrusted() else { return }
        isSuspended = false
        generation &+= 1
        unchangedPolls = 0
        currentInterval = fastInterval
        observeActivity()
        schedule(interval: fastInterval)
    }

    // MARK: Scheduling

    private func schedule(interval: TimeInterval) {
        guard !isSuspended else { return }
        timer?.invalidate()
        currentInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.dispatchPoll()
        }
        // Keep D1's tolerance on every initial/re-arm/backoff path.
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Anything plausibly preceding a selection change returns polling to 1 Hz.
    private func observeActivity() {
        removeActivityObservers()
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.resetBackoff() }
        activityObservers = [observer]

        scrollMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseUp]
        ) { [weak self] _ in self?.resetBackoff() }
    }

    private func removeActivityObservers() {
        activityObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        activityObservers = []
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        scrollMonitor = nil
    }

    private func resetBackoff() {
        guard !isSuspended else { return }
        unchangedPolls = 0
        guard currentInterval != fastInterval else { return }
        schedule(interval: fastInterval)
    }

    private func noteUnchanged() {
        guard !isSuspended, currentInterval == fastInterval else { return }
        unchangedPolls += 1
        if unchangedPolls >= backoffAfterIdlePolls {
            schedule(interval: slowInterval)
        }
    }

    private func noteChanged() {
        guard !isSuspended else { return }
        unchangedPolls = 0
        if currentInterval != fastInterval { schedule(interval: fastInterval) }
    }

    // MARK: Polling

    private func dispatchPoll() {
        guard !isSuspended, !pollInFlight else { return }
        guard AXIsProcessTrusted() else {
            onTrustLost?()
            return
        }
        pollInFlight = true
        let dispatchedGeneration = generation

        axQueue.async { [weak self] in
            guard let self else { return }
            let result = self.readFocusedSelection()
            DispatchQueue.main.async { [weak self] in
                self?.finishPoll(result, generation: dispatchedGeneration)
            }
        }
    }

    /// Always clears `pollInFlight`, but only the current active generation may touch
    /// dedup state, publish, or change the timer/backoff.
    private func finishPoll(_ result: PollResult?, generation dispatchedGeneration: UInt64) {
        pollInFlight = false
        guard !isSuspended, dispatchedGeneration == generation else { return }
        guard let result else { noteUnchanged(); return }

        let actualApp = result.pid.flatMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }

        let translatorFlippedOn = result.translator && !lastTranslatorContext
        lastTranslatorContext = result.translator

        var changedSelection: SelectionPayload?
        if let selection = result.selection,
           selection.hashPrefix != lastSelectionHash || result.docID != lastSelectionDocID {
            lastSelectionHash = selection.hashPrefix
            lastSelectionDocID = result.docID
            changedSelection = SelectionPayload(
                app: actualApp,
                charCount: selection.charCount,
                wordCount: selection.wordCount,
                language: selection.language,
                langConfidence: selection.langConfidence,
                isForeignLanguage: selection.isForeignLanguage,
                shape: selection.shape,
                hashPrefix: selection.hashPrefix,
                docID: result.docID,
                isTranslatorContext: result.translator)
        } else if result.selection == nil {
            // Absence is the separator between two real selections. Without resetting
            // here, selecting the same phrase again (or in another document) is
            // suppressed forever and repeat_selection cannot be observed honestly.
            lastSelectionHash = ""
            lastSelectionDocID = nil
        }

        if translatorFlippedOn {
            publish(payload: SelectionPayload(
                app: actualApp, charCount: 0, wordCount: 0,
                language: nil, langConfidence: nil, isForeignLanguage: false,
                shape: "", hashPrefix: "", docID: result.docID,
                isTranslatorContext: true))
        }
        if let changedSelection { publish(payload: changedSelection) }

        (translatorFlippedOn || changedSelection != nil) ? noteChanged() : noteUnchanged()
    }

    /// Runs entirely on `axQueue`. Raw selection text is classified here and discarded
    /// before the result returns to main.
    private func readFocusedSelection() -> PollResult? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let ref = focusedRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }

        let focused = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.5)

        var actualPID: pid_t = 0
        let pid: pid_t? = AXUIElementGetPid(focused, &actualPID) == .success ? actualPID : nil
        let (docID, translator) = windowContext(of: focused)

        var selectionRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString,
                                      &selectionRef)
        let text = (selectionRef as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var payload: SelectionPayload?
        if let text, text.count >= 3 {
            let scalars = IntentText.scalars(for: text, withEmbedding: false)
            payload = SelectionPayload(
                app: nil,
                charCount: scalars.charCount,
                wordCount: scalars.wordCount,
                language: scalars.language,
                langConfidence: scalars.langConfidence,
                isForeignLanguage: scalars.isForeignLanguage,
                shape: scalars.shape,
                hashPrefix: scalars.hashPrefix,
                docID: docID,
                isTranslatorContext: translator)
        }

        return PollResult(pid: pid, docID: docID, translator: translator,
                          selection: payload)
    }

    private func publish(payload: SelectionPayload) {
        guard !isSuspended else { return }
        bus?.publish(.live(kind: .selection, selection: payload))
    }

    /// Document identity + translator context from the focused element's window.
    /// Title and document path are hashed/matched here and never stored.
    private func windowContext(of element: AXUIElement) -> (docID: String?, translator: Bool) {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                kAXWindowAttribute as CFString, &windowRef) == .success,
              let ref = windowRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return (nil, false) }

        let window = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)

        var documentRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString,
                                      &documentRef)
        let document = documentRef as? String

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        let identity = document ?? title
        let docID = identity.map { IntentText.hashPrefix($0) }
        let haystack = ((document ?? "") + " " + (title ?? "")).lowercased()
        let translator = Self.translatorMarkers.contains { haystack.contains($0) }
        return (docID, translator)
    }
}
