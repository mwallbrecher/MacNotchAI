import AppKit
import ApplicationServices

// THESIS (L1 sensor, M2) — selection + bounded target-document context via
// Accessibility. This is the only permission-gated sensor in the pipeline.
//
// AX is synchronous cross-process IPC. Observer callbacks therefore only enqueue a
// debounced read; every content-bearing attribute/value/file read runs on one serial
// utility queue, with a 0.5 s timeout installed on every AX element. Observer
// registration uses a shorter timeout on main. Lifecycle generation/PID plus a
// same-process observation revision reject late work after pause, sleep, stop, trust
// loss, app switch or an intervening focus/selection/value/layout/scroll mutation.
//
// Privacy boundary: raw selection text, bounded document samples, AXDocument paths,
// and window titles die on the utility queue. Only classified scalars and hashed
// document identity can cross back to MainActor / SignalBus. Secure text fields are
// rejected immediately after the role/subrole probe, before any window, document,
// range, value, or selected-text attribute is requested.
final class SelectionSensor: IntentSensor {

    let name = "selection"

    private weak var bus: SignalBus?
    private var isSuspended = true
    private var generation: UInt64 = 0
    /// Same-PID observation boundary. AX calls cannot be cancelled, so a completion
    /// dispatched before a focus, content, selection, layout, or scroll change must be
    /// rejected explicitly instead of being published with a newer event timestamp.
    private var observationRevision: UInt64 = 0

    private var lastSelectionHash = ""
    private var lastSelectionDocID: String?
    private var lastTranslatorContext = false
    private var lastContextSignature: String?

    /// AX and local DOCX reads happen here, never on main. Serial execution prevents
    /// concurrent synchronous calls into a stalled target process.
    private let axQueue = DispatchQueue(label: "com.aidrop.intent.ax", qos: .utility)
    private var readInFlight = false
    private var pendingTrigger: ReadTrigger?
    private var debouncedTrigger: ReadTrigger?
    private var debounceTimer: Timer?
    private var fallbackTimer: Timer?

    private var activePID: pid_t?
    private var activeBundleID: String?
    private var activityObservers: [NSObjectProtocol] = []
    private var activityMonitor: Any?
    private var trustLossReported = false

    // AXObserver state is main-runloop-owned. Notification callbacks receive only an
    // integer token; the process-wide table holds a WEAK owner, so AX never keeps a
    // stopped sensor alive and a queued callback becomes a harmless no-op on teardown.
    private var axObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var observedFocusedWindow: AXUIElement?
    private var appRegistrations: [ObserverRegistration] = []
    private var focusedRegistrations: [ObserverRegistration] = []
    private var windowRegistrations: [ObserverRegistration] = []
    private var observerTokenID: UInt?

    private static var nextObserverTokenID: UInt = 0
    private static var callbackOwners: [UInt: WeakOwner] = [:]

    /// Derived-only DOCX cache. This property is touched exclusively by `axQueue`.
    /// Keys contain only hashed identity + mtime; values contain language scalars —
    /// never a file URL, path, title, or text sample.
    private var docxCache: [DocxCacheKey: CachedDocumentScalars] = [:]
    private var docxLastAttemptAt: [String: TimeInterval] = [:]

    /// The grant can be removed while the process is running. IntentEngine records
    /// that coverage boundary and removes this sensor instead of silently treating
    /// inaccessible context as negative evidence.
    var onTrustLost: (() -> Void)?

    /// Called synchronously at a conclusive same-process document/window boundary,
    /// before the replacement AX read is queued. IntentEngine first reconciles any
    /// pending copy under the old segment, then writes a content-free boundary so live
    /// inference and replay advance the same document revision.
    var onAccessibilityTargetBoundary: ((String?) -> Void)?

    private static let fallbackInterval: TimeInterval = 14
    private static let observerMessagingTimeout: Float = 0.15
    private static let maximumSampleChars = 4_000
    private static let maximumSelectionChars = 40_000
    private static let maximumWholeValueChars = 12_000
    private static let maximumDocxBytes = 8 * 1_024 * 1_024
    private static let maximumDocxExpandedBytes = 32 * 1_024 * 1_024
    private static let maximumDocxXMLBytes = 2 * 1_024 * 1_024
    private static let maximumDocxCacheEntries = 32
    private static let docxRetryInterval: TimeInterval = 60

    private static let allowedDocumentExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "rtfd", "pdf", "doc", "docx", "odt",
        "pages", "csv", "tsv", "xls", "xlsx", "numbers", "ppt", "pptx", "key",
        "html", "htm",
    ]

    private static let translatorMarkers = [
        "deepl", "translate", "translator", "linguee", "dict.cc", "leo.org",
        "reverso", "übersetzer", "wörterbuch", "dictionary",
    ]

    private enum ReadTrigger: String {
        case initial, focus, selection, value, layout, scroll, fallback

        var debounce: TimeInterval {
            switch self {
            case .initial, .fallback: return 0
            case .selection: return 0.08
            case .focus, .value: return 0.16
            case .layout, .scroll: return 0.28
            }
        }

        /// Preserve the most semantically useful trigger while callbacks coalesce.
        /// In particular, a trailing value callback must not relabel a scroll/layout
        /// observation and make real visible-range movement look non-navigational.
        var priority: Int {
            switch self {
            case .scroll: return 7
            case .layout: return 6
            case .focus: return 5
            case .selection: return 4
            case .value: return 3
            case .initial: return 2
            case .fallback: return 1
            }
        }

        /// Notifications and user navigation that can change any value read by the AX
        /// transaction invalidate its completion. Initial/fallback scheduling alone is
        /// not an observation change and therefore leaves the revision untouched.
        var invalidatesInFlightRead: Bool {
            switch self {
            case .focus, .selection, .value, .layout, .scroll: return true
            case .initial, .fallback: return false
            }
        }

        static func coalescing(_ current: ReadTrigger?, with incoming: ReadTrigger) -> ReadTrigger {
            guard let current else { return incoming }
            return current.priority >= incoming.priority ? current : incoming
        }
    }

    private struct ObserverRegistration {
        let element: AXUIElement
        let notification: CFString
        /// Unsupported notifications are remembered so every fallback read does not
        /// repeat the same IPC. Transient errors are deliberately not remembered.
        let isRegistered: Bool
    }

    private final class WeakOwner {
        weak var value: SelectionSensor?
        init(_ value: SelectionSensor) { self.value = value }
    }

    private struct ReadRequest {
        let generation: UInt64
        let observationRevision: UInt64
        let pid: pid_t
        let bundleID: String?
        let trigger: ReadTrigger
    }

    private struct SelectionScalars {
        let charCount: Int
        let wordCount: Int
        let language: String?
        let langConfidence: Double?
        let isForeignLanguage: Bool
        let shape: String
        let hashPrefix: String
    }

    private struct ContextScalars {
        let docID: String?
        let documentExtension: String?
        let focusedRole: String
        let editable: Bool?
        let language: String?
        let langConfidence: Double?
        let sampleCharCount: Int
        let readStrategy: String
        let caretBucket: Int?
        let visibleStartBucket: Int?
        let visibleEndBucket: Int?
    }

    private struct ReadResult {
        /// PID comes from the AX element itself, preventing app-B content from being
        /// labelled with app A's frontmost snapshot during a fast switch.
        let pid: pid_t
        let focusedElement: AXUIElement
        let focusedWindow: AXUIElement?
        let docID: String?
        let translator: Bool
        let selection: SelectionScalars?
        let context: ContextScalars?
    }

    /// Raw identity/path/title remain scoped to the utility read and are never part
    /// of `ReadResult` except for the derived hash/allowlisted extension.
    private struct DocumentContext {
        let docID: String?
        let documentExtension: String?
        let localDocxURL: URL?
        let translator: Bool
        let windowElement: AXUIElement?
    }

    private struct TextSample {
        let language: String?
        let confidence: Double?
        let charCount: Int
    }

    private struct DocxCacheKey: Hashable {
        let docID: String
        let modificationBits: UInt64
    }

    private struct CachedDocumentScalars {
        let language: String?
        let confidence: Double?
        let sampleCharCount: Int
    }

    private enum AXStringProbe {
        case value(String)
        /// AX explicitly reports that this optional attribute is absent/unsupported.
        case absent
        /// Transport, timeout, invalid-element, type, or other ambiguous failure.
        case failed
    }

    private enum SubroleDecision {
        case secure
        case proceed(String?)
        case failClosed
    }

    // MARK: Lifecycle

    func start(bus: SignalBus) {
        self.bus = bus
        resume()
    }

    func stop() {
        suspend()
        bus = nil
    }

    /// Invalidates timers, observer callbacks, queued completions, and pending reads.
    /// A synchronous AX call already running cannot be cancelled, but its generation
    /// can no longer publish or rebind anything after this method returns.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        generation &+= 1
        debounceTimer?.invalidate()
        debounceTimer = nil
        debouncedTrigger = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pendingTrigger = nil
        removeActivityObservers()
        tearDownAXObserver()
        activePID = nil
        activeBundleID = nil
        resetDedupState()
    }

    func resume() {
        guard isSuspended, bus != nil else { return }
        guard AXIsProcessTrusted() else {
            reportTrustLoss()
            return
        }

        isSuspended = false
        generation &+= 1
        trustLossReported = false
        resetDedupState()
        observeActivity()
        scheduleFallback()
        bindToFrontmostApplication(trigger: .initial)
    }

    private func resetDedupState() {
        lastSelectionHash = ""
        lastSelectionDocID = nil
        lastTranslatorContext = false
        lastContextSignature = nil
    }

    // MARK: Observer-first scheduling

    private func observeActivity() {
        removeActivityObservers()
        let activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bindToFrontmostApplication(trigger: .focus)
        }
        activityObservers = [activation]

        // Some apps expose none of the relevant AX notifications. Keep the previous
        // user-driven coverage: scroll and mouse-up schedule a bounded read, without
        // returning to continuous fast polling.
        activityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trigger: ReadTrigger = event.type == .scrollWheel ? .scroll : .focus
                // Scroll may change visible ranges just as mouse-up may move focus in
                // an app without AX notifications. Neither may let an older same-PID
                // transaction publish stale scalars before the queued correction.
                if trigger.invalidatesInFlightRead { self.observationRevision &+= 1 }
                self.enqueueRead(trigger: trigger)
            }
        }
    }

    private func removeActivityObservers() {
        activityObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        activityObservers = []
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        activityMonitor = nil
    }

    private func scheduleFallback() {
        fallbackTimer?.invalidate()
        let timer = Timer(timeInterval: Self.fallbackInterval, repeats: true) {
            [weak self] _ in self?.enqueueRead(trigger: .fallback)
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    /// An app switch is a hard lifecycle boundary. Observer subscriptions and queued
    /// reads are invalidated before binding the new frontmost PID.
    private func bindToFrontmostApplication(trigger: ReadTrigger) {
        guard !isSuspended else { return }
        guard AXIsProcessTrusted() else {
            reportTrustLoss()
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        let pid = app.processIdentifier
        let bundleID = Self.nonEmpty(app.bundleIdentifier)
        if activePID == pid {
            activeBundleID = bundleID
            enqueueRead(trigger: trigger)
            return
        }

        generation &+= 1
        debounceTimer?.invalidate()
        debounceTimer = nil
        debouncedTrigger = nil
        pendingTrigger = nil
        tearDownAXObserver()
        resetDedupState()

        activePID = pid
        activeBundleID = bundleID
        installAXObserver(for: pid)
        enqueueRead(trigger: trigger)
    }

    /// Creates one AXObserver for the frontmost process and installs its source on
    /// CFRunLoopGetMain(), which is continuously serviced by the app. Unsupported
    /// notifications are ignored individually; scroll/mouse + 14 s fallback remain.
    private func installAXObserver(for pid: pid_t) {
        guard !isSuspended, activePID == pid else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, selectionSensorAXObserverCallback, &created) == .success,
              let observer = created else { return }

        Self.nextObserverTokenID &+= 1
        if Self.nextObserverTokenID == 0 { Self.nextObserverTokenID = 1 }
        let tokenID = Self.nextObserverTokenID
        Self.callbackOwners[tokenID] = WeakOwner(self)

        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.observerMessagingTimeout)

        axObserver = observer
        observedApplication = application
        observerTokenID = tokenID

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        let token = UnsafeMutableRawPointer(bitPattern: tokenID)
        addNotification(kAXFocusedUIElementChangedNotification as CFString,
                        element: application, observer: observer, token: token,
                        registrations: &appRegistrations)
        addNotification(kAXFocusedWindowChangedNotification as CFString,
                        element: application, observer: observer, token: token,
                        registrations: &appRegistrations)
    }

    private func bindFocusedNotifications(to element: AXUIElement,
                                          pid: pid_t,
                                          generation dispatchedGeneration: UInt64) {
        guard !isSuspended,
              dispatchedGeneration == generation,
              activePID == pid,
              let observer = axObserver,
              let tokenID = observerTokenID else { return }

        let sameElement = observedFocusedElement.map { CFEqual($0, element) } == true
        if !sameElement {
            removeFocusedRegistrations()
            observedFocusedElement = element
        }
        AXUIElementSetMessagingTimeout(element, Self.observerMessagingTimeout)

        let token = UnsafeMutableRawPointer(bitPattern: tokenID)
        addNotification(kAXSelectedTextChangedNotification as CFString,
                        element: element, observer: observer, token: token,
                        registrations: &focusedRegistrations)
        addNotification(kAXValueChangedNotification as CFString,
                        element: element, observer: observer, token: token,
                        registrations: &focusedRegistrations)
        addNotification(kAXLayoutChangedNotification as CFString,
                        element: element, observer: observer, token: token,
                        registrations: &focusedRegistrations)
        addNotification(kAXUIElementDestroyedNotification as CFString,
                        element: element, observer: observer, token: token,
                        registrations: &focusedRegistrations)
    }

    private func bindWindowNotifications(to window: AXUIElement?,
                                         pid: pid_t,
                                         generation dispatchedGeneration: UInt64) {
        guard !isSuspended,
              dispatchedGeneration == generation,
              activePID == pid,
              let observer = axObserver,
              let tokenID = observerTokenID else { return }

        guard let window else {
            removeWindowRegistrations()
            return
        }
        let sameWindow = observedFocusedWindow.map { CFEqual($0, window) } == true
        if !sameWindow {
            removeWindowRegistrations()
            observedFocusedWindow = window
        }
        AXUIElementSetMessagingTimeout(window, Self.observerMessagingTimeout)

        let token = UnsafeMutableRawPointer(bitPattern: tokenID)
        addNotification(kAXLayoutChangedNotification as CFString,
                        element: window, observer: observer, token: token,
                        registrations: &windowRegistrations)
        addNotification(kAXTitleChangedNotification as CFString,
                        element: window, observer: observer, token: token,
                        registrations: &windowRegistrations)
    }

    private func addNotification(_ notification: CFString,
                                 element: AXUIElement,
                                 observer: AXObserver,
                                 token: UnsafeMutableRawPointer?,
                                 registrations: inout [ObserverRegistration]) {
        guard !registrations.contains(where: {
            CFEqual($0.element, element) && CFEqual($0.notification, notification)
        }) else { return }
        let result = AXObserverAddNotification(observer, element, notification, token)
        if result == .success || result == .notificationAlreadyRegistered {
            registrations.append(ObserverRegistration(element: element,
                                                      notification: notification,
                                                      isRegistered: true))
        } else if result == .notificationUnsupported {
            registrations.append(ObserverRegistration(element: element,
                                                      notification: notification,
                                                      isRegistered: false))
        }
    }

    private func removeFocusedRegistrations() {
        if let observer = axObserver {
            focusedRegistrations.filter(\.isRegistered).forEach {
                AXObserverRemoveNotification(observer, $0.element, $0.notification)
            }
        }
        focusedRegistrations = []
        observedFocusedElement = nil
    }

    private func removeWindowRegistrations() {
        if let observer = axObserver {
            windowRegistrations.filter(\.isRegistered).forEach {
                AXObserverRemoveNotification(observer, $0.element, $0.notification)
            }
        }
        windowRegistrations = []
        observedFocusedWindow = nil
    }

    private func tearDownAXObserver() {
        // Remove the weak routing entry first. Even a callback already queued on the
        // runloop can no longer reach this sensor after the lifecycle boundary.
        if let observerTokenID { Self.callbackOwners.removeValue(forKey: observerTokenID) }
        observerTokenID = nil

        removeFocusedRegistrations()
        removeWindowRegistrations()
        if let observer = axObserver {
            appRegistrations.filter(\.isRegistered).forEach {
                AXObserverRemoveNotification(observer, $0.element, $0.notification)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
                                  .commonModes)
        }
        appRegistrations = []
        observedApplication = nil
        axObserver = nil
    }

    fileprivate static func receiveAXNotification(tokenID: UInt,
                                                  notification: String) {
        guard let sensor = callbackOwners[tokenID]?.value, !sensor.isSuspended else { return }
        if notification == "AXFocusedWindowChanged"
            || notification == "AXTitleChanged" {
            sensor.onAccessibilityTargetBoundary?(sensor.activeBundleID)
        }
        let trigger: ReadTrigger
        switch notification {
        case "AXSelectedTextChanged":
            trigger = .selection
        case "AXValueChanged":
            trigger = .value
        case "AXLayoutChanged":
            trigger = .layout
        default:
            trigger = .focus
        }
        if trigger.invalidatesInFlightRead { sensor.observationRevision &+= 1 }
        // Callback work ends here: one timer enqueue, never synchronous AX IPC.
        sensor.enqueueRead(trigger: trigger)
    }

    private func enqueueRead(trigger: ReadTrigger) {
        guard !isSuspended else { return }
        guard AXIsProcessTrusted() else {
            reportTrustLoss()
            return
        }

        // didActivate may be waiting behind the current event. Treat the live PID as
        // authoritative so no read is dispatched against a stale app generation.
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontPID != activePID {
            bindToFrontmostApplication(trigger: .focus)
            return
        }

        if readInFlight {
            pendingTrigger = ReadTrigger.coalescing(pendingTrigger, with: trigger)
            return
        }

        debouncedTrigger = ReadTrigger.coalescing(debouncedTrigger, with: trigger)
        guard let coalesced = debouncedTrigger else { return }
        guard coalesced.debounce > 0 else {
            debounceTimer?.invalidate()
            debounceTimer = nil
            debouncedTrigger = nil
            dispatchRead(trigger: coalesced)
            return
        }

        if let timer = debounceTimer {
            // Reuse the timer under callback bursts; only its fire date and the
            // priority-coalesced trigger change.
            timer.fireDate = Date(timeIntervalSinceNow: coalesced.debounce)
            return
        }

        let timer = Timer(timeInterval: coalesced.debounce, repeats: false) {
            [weak self] _ in self?.dispatchDebouncedRead()
        }
        timer.tolerance = min(0.05, coalesced.debounce * 0.25)
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    private func dispatchDebouncedRead() {
        guard let trigger = debouncedTrigger else { return }
        debouncedTrigger = nil
        dispatchRead(trigger: trigger)
    }

    private func dispatchRead(trigger: ReadTrigger) {
        debounceTimer?.invalidate()
        debounceTimer = nil
        debouncedTrigger = nil
        guard !isSuspended, !readInFlight,
              let pid = activePID else { return }
        guard AXIsProcessTrusted() else {
            reportTrustLoss()
            return
        }

        readInFlight = true
        let request = ReadRequest(generation: generation,
                                  observationRevision: observationRevision,
                                  pid: pid, bundleID: activeBundleID, trigger: trigger)
        axQueue.async { [weak self] in
            guard let self else { return }
            let result = self.readFocusedTarget(expectedPID: request.pid)
            DispatchQueue.main.async { [weak self] in
                self?.finishRead(result, request: request)
            }
        }
    }

    private func finishRead(_ result: ReadResult?, request: ReadRequest) {
        readInFlight = false
        defer {
            if !isSuspended, let next = pendingTrigger {
                pendingTrigger = nil
                enqueueRead(trigger: next)
            }
        }

        guard !isSuspended,
              request.generation == generation,
              Self.completionIsCurrent(requestRevision: request.observationRevision,
                                       currentRevision: observationRevision),
              request.pid == activePID else { return }
        guard AXIsProcessTrusted() else {
            reportTrustLoss()
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == request.pid else {
            bindToFrontmostApplication(trigger: .focus)
            return
        }
        guard let result, result.pid == request.pid else { return }

        bindFocusedNotifications(to: result.focusedElement, pid: result.pid,
                                 generation: request.generation)
        bindWindowNotifications(to: result.focusedWindow, pid: result.pid,
                                generation: request.generation)

        let app = Self.nonEmpty(
            NSRunningApplication(processIdentifier: result.pid)?.bundleIdentifier
        ) ?? request.bundleID

        let translatorFlippedOn = result.translator && !lastTranslatorContext
        lastTranslatorContext = result.translator

        var changedSelection: SelectionPayload?
        if let selection = result.selection,
           selection.hashPrefix != lastSelectionHash || result.docID != lastSelectionDocID {
            lastSelectionHash = selection.hashPrefix
            lastSelectionDocID = result.docID
            changedSelection = SelectionPayload(
                app: app,
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
            // Absence separates two real selections. Selecting the same phrase later
            // must remain observable as repeat_selection evidence.
            lastSelectionHash = ""
            lastSelectionDocID = nil
        }

        if translatorFlippedOn {
            publishSelection(SelectionPayload(
                app: app, charCount: 0, wordCount: 0,
                language: nil, langConfidence: nil, isForeignLanguage: false,
                shape: "", hashPrefix: "", docID: result.docID,
                isTranslatorContext: true))
        }
        if let changedSelection { publishSelection(changedSelection) }

        guard let context = result.context else {
            lastContextSignature = nil
            return
        }
        let payload = AccessibilityContextPayload(
            app: app,
            docID: context.docID,
            documentExtension: context.documentExtension,
            focusedRole: context.focusedRole,
            editable: context.editable,
            language: context.language,
            langConfidence: context.langConfidence,
            sampleCharCount: context.sampleCharCount,
            readStrategy: context.readStrategy,
            caretBucket: context.caretBucket,
            visibleStartBucket: context.visibleStartBucket,
            visibleEndBucket: context.visibleEndBucket,
            trigger: request.trigger.rawValue)

        let signature = Self.contextSignature(payload)
        guard signature != lastContextSignature else { return }
        lastContextSignature = signature
        bus?.publish(.live(kind: .accessibilityContext, accessibilityContext: payload))
    }

    private func reportTrustLoss() {
        guard !trustLossReported else { return }
        trustLossReported = true
        generation &+= 1
        debounceTimer?.invalidate()
        debounceTimer = nil
        debouncedTrigger = nil
        pendingTrigger = nil
        tearDownAXObserver()
        onTrustLost?()
    }

    // MARK: Utility-queue AX read

    /// Queries role and subrole before every content-bearing attribute. A secure
    /// subrole returns a result solely so observer rebinding stays live; selection and
    /// context are nil and no window/document/range/value read occurs.
    private func readFocusedTarget(expectedPID: pid_t) -> ReadResult? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let rawFocused = focusedRef,
              CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else { return nil }

        let focused = rawFocused as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.5)

        // SECURITY ORDER IS LOAD-BEARING. Do not move any content/window read above it.
        guard let rawRole = Self.stringAttribute(kAXRoleAttribute as CFString, of: focused) else {
            return nil // fail closed when the role cannot be established
        }
        let subroleProbe = Self.stringProbe(kAXSubroleAttribute as CFString, of: focused)

        var actualPID: pid_t = 0
        guard AXUIElementGetPid(focused, &actualPID) == .success,
              actualPID == expectedPID else { return nil }

        let rawSubrole: String?
        switch Self.subroleDecision(for: subroleProbe) {
        case .secure:
            return ReadResult(pid: actualPID, focusedElement: focused, focusedWindow: nil,
                              docID: nil, translator: false, selection: nil, context: nil)
        case .proceed(let subrole):
            rawSubrole = subrole
        case .failClosed:
            return nil // fail closed before any document/title/range/value read
        }

        let document = Self.documentContext(of: focused)
        let selection = Self.selectionScalars(of: focused)
        let context = contextScalars(of: focused, role: rawRole,
                                     subrole: rawSubrole, document: document)
        return ReadResult(pid: actualPID, focusedElement: focused,
                          focusedWindow: document.windowElement,
                          docID: document.docID, translator: document.translator,
                          selection: selection, context: context)
    }

    private static func selectionScalars(of focused: AXUIElement) -> SelectionScalars? {
        // AXSelectedText has no caller-side length parameter. Establish the selection
        // range first, prefer a bounded AXStringForRange request, and use SelectedText
        // only when the app reports that the complete selection is already below the
        // cap. Unknown or huge selections fail closed instead of crossing IPC whole.
        guard let selectedRange = rangeAttribute(
            kAXSelectedTextRangeAttribute as CFString, of: focused),
              selectedRange.length >= 3,
              safeRangeEnd(selectedRange) != nil else { return nil }
        let requested = CFRange(location: selectedRange.location,
                                length: min(selectedRange.length, maximumSelectionChars))
        let raw = stringForRange(requested, of: focused)
            ?? (selectedRange.length <= maximumSelectionChars
                ? stringAttribute(kAXSelectedTextAttribute as CFString, of: focused)
                : nil)
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let text = String(trimmed.prefix(maximumSelectionChars))
        let scalars = IntentText.scalars(for: text, withEmbedding: false)
        let language = normalizedLanguage(scalars.language)
        return SelectionScalars(
            charCount: scalars.charCount,
            wordCount: scalars.wordCount,
            language: language,
            langConfidence: language == nil ? nil : scalars.langConfidence,
            isForeignLanguage: scalars.isForeignLanguage,
            shape: scalars.shape,
            hashPrefix: scalars.hashPrefix)
    }

    private func contextScalars(of focused: AXUIElement,
                                role rawRole: String,
                                subrole rawSubrole: String?,
                                document: DocumentContext) -> ContextScalars {
        let focusedRole = Self.roleCategory(role: rawRole, subrole: rawSubrole)
        let editable = Self.isEditable(focused)

        let totalCharacters = Self.integerAttribute(
            kAXNumberOfCharactersAttribute as CFString, of: focused)
        let selectedRange = Self.rangeAttribute(
            kAXSelectedTextRangeAttribute as CFString, of: focused)
        let visibleRange = Self.rangeAttribute(
            kAXVisibleCharacterRangeAttribute as CFString, of: focused)

        let caretBucket = Self.progressBucket(
            selectedRange.flatMap(Self.safeRangeEnd), total: totalCharacters)
        let visibleStartBucket = Self.progressBucket(
            visibleRange?.location, total: totalCharacters)
        let visibleEndBucket = Self.progressBucket(
            visibleRange.flatMap(Self.safeRangeEnd), total: totalCharacters)

        var sample: TextSample?
        var strategy = "none"

        // Target-local AX text outranks whole-document language: it is both cheaper
        // and semantically closer to the paste caret in multilingual documents.
        // DOCX import is a bounded fallback only when the app exposes no usable text.
        if let text = Self.rangeSample(of: focused, visibleRange: visibleRange,
                                      selectedRange: selectedRange,
                                      totalCharacters: totalCharacters) {
            sample = Self.classify(text)
            strategy = "visible_range"
        } else if Self.mayReadWholeValue(totalCharacters, role: focusedRole),
                  let value = Self.stringAttribute(kAXValueAttribute as CFString, of: focused),
                  let bounded = Self.boundedSample(value) {
            sample = Self.classify(bounded)
            strategy = "value"
        } else if let docID = document.docID,
                  let docxURL = document.localDocxURL,
                  let derived = readDocxScalars(url: docxURL, docID: docID) {
            sample = TextSample(language: derived.language,
                                confidence: derived.confidence,
                                charCount: derived.sampleCharCount)
            strategy = "document_file"
        }

        // Range metadata remains useful even when the app supports character ranges
        // but not AXStringForRange. It is represented explicitly, never disguised as
        // a successful text read, so translation cannot consume it as language data.
        let hasSample = sample.map { $0.charCount > 0 } == true
        if !hasSample {
            sample = nil
            strategy = [caretBucket, visibleStartBucket, visibleEndBucket]
                .contains(where: { $0 != nil }) ? "range_metadata" : "none"
        }

        return ContextScalars(
            docID: document.docID,
            documentExtension: document.documentExtension,
            focusedRole: focusedRole,
            editable: editable,
            language: sample?.language,
            langConfidence: sample?.confidence,
            sampleCharCount: sample?.charCount ?? 0,
            readStrategy: strategy,
            caretBucket: caretBucket,
            visibleStartBucket: visibleStartBucket,
            visibleEndBucket: visibleEndBucket)
    }

    // MARK: Minimal context reads

    private static func documentContext(of focused: AXUIElement) -> DocumentContext {
        var contextElement = focused
        var windowElement: AXUIElement?
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused, kAXWindowAttribute as CFString, &windowRef) == .success,
           let rawWindow = windowRef,
           CFGetTypeID(rawWindow) == AXUIElementGetTypeID() {
            contextElement = rawWindow as! AXUIElement
            windowElement = contextElement
            AXUIElementSetMessagingTimeout(contextElement, 0.5)
        }

        let windowDocument = stringAttribute(kAXDocumentAttribute as CFString, of: contextElement)
        let focusedDocument = windowElement != nil && nonEmpty(windowDocument) == nil
            ? stringAttribute(kAXDocumentAttribute as CFString, of: focused)
            : nil
        let rawDocument = nonEmpty(windowDocument) ?? nonEmpty(focusedDocument)
        let windowTitle = stringAttribute(kAXTitleAttribute as CFString, of: contextElement)
        let focusedTitle = windowElement != nil && nonEmpty(windowTitle) == nil
            ? stringAttribute(kAXTitleAttribute as CFString, of: focused)
            : nil
        let rawTitle = nonEmpty(windowTitle) ?? nonEmpty(focusedTitle)
        let identity = nonEmpty(rawDocument) ?? nonEmpty(rawTitle)
        let docID = identity.map(IntentText.hashPrefix)
        let haystack = ((rawDocument ?? "") + " " + (rawTitle ?? "")).lowercased()
        let translator = translatorMarkers.contains { haystack.contains($0) }

        let documentURL: URL?
        if let rawDocument {
            documentURL = localFileURL(rawDocument)
        } else {
            documentURL = nil
        }
        let candidateExtension: String? = {
            if let documentURL { return documentURL.pathExtension.lowercased() }
            guard let rawDocument, let parsed = URL(string: rawDocument) else { return nil }
            return parsed.pathExtension.lowercased()
        }()
        let allowedExtension = candidateExtension.flatMap {
            allowedDocumentExtensions.contains($0) ? $0 : nil
        }
        let localDocxURL = allowedExtension == "docx" ? documentURL : nil

        return DocumentContext(docID: docID,
                               documentExtension: allowedExtension,
                               localDocxURL: localDocxURL,
                               translator: translator,
                               windowElement: windowElement)
    }

    private func readDocxScalars(url: URL,
                                 docID: String) -> CachedDocumentScalars? {
        guard url.isFileURL, url.pathExtension.lowercased() == "docx" else { return nil }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .isUbiquitousItemKey, .volumeIsLocalKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0, size <= Self.maximumDocxBytes,
              let modified = values.contentModificationDate,
              values.volumeIsLocal == true,
              values.isUbiquitousItem != true else {
            return nil
        }

        let key = DocxCacheKey(docID: docID,
                               modificationBits: modified.timeIntervalSinceReferenceDate.bitPattern)
        if let cached = docxCache[key] { return cached }

        // Autosave can change mtime on every observer burst. At most one full Office
        // import per document/minute; range reads remain the immediate fallback.
        let now = ProcessInfo.processInfo.systemUptime
        if let lastAttempt = docxLastAttemptAt[docID],
           now - lastAttempt < Self.docxRetryInterval {
            return nil
        }
        if docxLastAttemptAt.count >= Self.maximumDocxCacheEntries,
           docxLastAttemptAt[docID] == nil,
           let arbitraryOldDocument = docxLastAttemptAt.keys.first {
            docxLastAttemptAt.removeValue(forKey: arbitraryOldDocument)
        }
        docxLastAttemptAt[docID] = now

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= Self.maximumDocxBytes,
              Self.docxArchiveLooksBounded(data) else { return nil }

        let text: String? = autoreleasepool {
            guard let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: nil) else { return nil }
            return Self.boundedSample(attributed.string)
        }
        guard let text else { return nil }

        // Reject a write racing the import so a stale mtime key is never populated.
        guard let after = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              after.contentModificationDate == modified else { return nil }

        let classified = Self.classify(text)
        let cached = CachedDocumentScalars(language: classified.language,
                                           confidence: classified.confidence,
                                           sampleCharCount: classified.charCount)
        docxCache.keys.filter { $0.docID == docID && $0 != key }.forEach {
            docxCache.removeValue(forKey: $0)
        }
        if docxCache.count >= Self.maximumDocxCacheEntries,
           let oldestArbitraryKey = docxCache.keys.first {
            docxCache.removeValue(forKey: oldestArbitraryKey)
        }
        docxCache[key] = cached
        return cached
    }

    /// Preflights the ZIP central directory before the Office importer can expand it.
    /// Compressed size alone does not bound a DOCX (a tiny ZIP can expand to GBs).
    /// ZIP64/encrypted/malformed archives are rejected; the normal AX range path then
    /// remains available without touching the file again for the retry interval.
    private static func docxArchiveLooksBounded(_ data: Data) -> Bool {
        let eocdSignature: UInt32 = 0x0605_4B50
        let centralSignature: UInt32 = 0x0201_4B50
        guard data.count >= 22 else { return false }

        let earliest = max(0, data.count - 65_557)
        var cursor = data.count - 22
        var eocdOffset: Int?
        while true {
            if littleEndianUInt32(data, at: cursor) == eocdSignature {
                eocdOffset = cursor
                break
            }
            if cursor == earliest { break }
            cursor -= 1
        }
        guard let eocdOffset,
              littleEndianUInt16(data, at: eocdOffset + 4) == 0,
              littleEndianUInt16(data, at: eocdOffset + 6) == 0,
              let entriesOnDisk = littleEndianUInt16(data, at: eocdOffset + 8),
              let entryCount = littleEndianUInt16(data, at: eocdOffset + 10),
              entriesOnDisk == entryCount,
              entryCount != UInt16.max,
              let centralSize32 = littleEndianUInt32(data, at: eocdOffset + 12),
              let centralOffset32 = littleEndianUInt32(data, at: eocdOffset + 16),
              centralSize32 != UInt32.max, centralOffset32 != UInt32.max else {
            return false
        }

        let centralSize = Int(centralSize32)
        let centralOffset = Int(centralOffset32)
        let centralEnd = centralOffset.addingReportingOverflow(centralSize)
        guard !centralEnd.overflow, centralOffset >= 0,
              centralEnd.partialValue <= eocdOffset else { return false }

        var offset = centralOffset
        var expandedTotal = 0
        var foundDocumentXML = false
        for _ in 0..<Int(entryCount) {
            guard littleEndianUInt32(data, at: offset) == centralSignature,
                  let flags = littleEndianUInt16(data, at: offset + 8),
                  let method = littleEndianUInt16(data, at: offset + 10),
                  let compressed32 = littleEndianUInt32(data, at: offset + 20),
                  let expanded32 = littleEndianUInt32(data, at: offset + 24),
                  let nameLength16 = littleEndianUInt16(data, at: offset + 28),
                  let extraLength16 = littleEndianUInt16(data, at: offset + 30),
                  let commentLength16 = littleEndianUInt16(data, at: offset + 32),
                  compressed32 != UInt32.max, expanded32 != UInt32.max,
                  flags & 0x0001 == 0 else { return false }

            let expanded = Int(expanded32)
            let nextTotal = expandedTotal.addingReportingOverflow(expanded)
            guard !nextTotal.overflow,
                  nextTotal.partialValue <= maximumDocxExpandedBytes else { return false }
            expandedTotal = nextTotal.partialValue

            let nameLength = Int(nameLength16)
            let extraLength = Int(extraLength16)
            let commentLength = Int(commentLength16)
            guard nameLength <= 1_024 else { return false }
            let nameStart = offset.addingReportingOverflow(46)
            let nameEnd = nameStart.partialValue.addingReportingOverflow(nameLength)
            guard !nameStart.overflow, !nameEnd.overflow,
                  nameStart.partialValue >= 0, nameEnd.partialValue <= data.count else {
                return false
            }

            if data[nameStart.partialValue..<nameEnd.partialValue]
                .elementsEqual("word/document.xml".utf8) {
                guard (method == 0 || method == 8),
                      compressed32 <= UInt32(maximumDocxBytes),
                      expanded <= maximumDocxXMLBytes else { return false }
                foundDocumentXML = true
            }

            let headerAndName = 46.addingReportingOverflow(nameLength)
            let withExtra = headerAndName.partialValue.addingReportingOverflow(extraLength)
            let entryLength = withExtra.partialValue.addingReportingOverflow(commentLength)
            let nextOffset = offset.addingReportingOverflow(entryLength.partialValue)
            guard !headerAndName.overflow, !withExtra.overflow, !entryLength.overflow,
                  !nextOffset.overflow, nextOffset.partialValue <= centralEnd.partialValue else {
                return false
            }
            offset = nextOffset.partialValue
        }
        return foundDocumentXML && offset == centralEnd.partialValue
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 2 else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// AXStringForRange is preferred over AXValue. It requests at most 4,000 chars
    /// from the visible range, then a bounded window around the caret (or document
    /// start when only total length is exposed). No window-tree traversal occurs.
    private static func rangeSample(of element: AXUIElement,
                                    visibleRange: CFRange?,
                                    selectedRange: CFRange?,
                                    totalCharacters: Int?) -> String? {
        if let visibleRange,
           let range = boundedAXRange(visibleRange, total: totalCharacters,
                                      centeredAt: selectedRange?.location),
           let text = stringForRange(range, of: element),
           let bounded = boundedSample(text) {
            return bounded
        }

        if let totalCharacters, totalCharacters > 0 {
            let caret = min(max(selectedRange?.location ?? 0, 0), totalCharacters)
            let half = maximumSampleChars / 2
            let start = max(0, min(caret - half, totalCharacters - 1))
            let length = min(maximumSampleChars, totalCharacters - start)
            let range = CFRange(location: start, length: length)
            if let text = stringForRange(range, of: element),
               let bounded = boundedSample(text) {
                return bounded
            }
        } else if totalCharacters == nil {
            // Some AX clients omit AXNumberOfCharacters but still implement the
            // parameterized range API. A fixed request remains bounded by contract.
            let range = CFRange(location: 0, length: maximumSampleChars)
            if let text = stringForRange(range, of: element),
               let bounded = boundedSample(text) {
                return bounded
            }
        }
        return nil
    }

    private static func stringForRange(_ requestedRange: CFRange,
                                       of element: AXUIElement) -> String? {
        var range = requestedRange
        guard range.location >= 0, range.length > 0,
              let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success else { return nil }
        return result as? String
    }

    private static func boundedAXRange(_ raw: CFRange,
                                       total: Int?,
                                       centeredAt caret: Int?) -> CFRange? {
        guard raw.location >= 0, raw.length > 0 else { return nil }
        let rawEnd = raw.location.addingReportingOverflow(raw.length)
        guard !rawEnd.overflow else { return nil }
        let upper = total.map { min(max($0, 0), rawEnd.partialValue) } ?? rawEnd.partialValue
        guard upper > raw.location else { return nil }

        let available = upper - raw.location
        guard available > maximumSampleChars else {
            return CFRange(location: raw.location, length: available)
        }

        let desiredCenter = min(max(caret ?? raw.location, raw.location), upper)
        let proposedStart = desiredCenter - maximumSampleChars / 2
        let start = min(max(raw.location, proposedStart), upper - maximumSampleChars)
        return CFRange(location: start, length: maximumSampleChars)
    }

    private static func mayReadWholeValue(_ total: Int?, role: String) -> Bool {
        // AXValue itself cannot be range-limited. Use it only when the client reports
        // a small value and the focused role is text-bearing; unknown length fails
        // closed and AXStringForRange above gets the bounded opportunity instead.
        guard let total, total >= 0, total <= maximumWholeValueChars else { return false }
        return ["text_field", "text_area", "search_field"].contains(role)
    }

    private static func boundedSample(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumSampleChars))
    }

    private static func classify(_ text: String) -> TextSample {
        let bounded = String(text.prefix(maximumSampleChars))
        let scalars = IntentText.scalars(for: bounded, withEmbedding: false)
        let language = normalizedLanguage(scalars.language)
        return TextSample(language: language,
                          confidence: language == nil ? nil : scalars.langConfidence,
                          charCount: bounded.count)
    }

    // MARK: AX scalar helpers

    private static func stringAttribute(_ attribute: CFString,
                                        of element: AXUIElement) -> String? {
        guard case .value(let value) = stringProbe(attribute, of: element) else {
            return nil
        }
        return value
    }

    private static func stringProbe(_ attribute: CFString,
                                    of element: AXUIElement) -> AXStringProbe {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        switch error {
        case .attributeUnsupported, .noValue:
            return .absent
        case .success:
            guard let string = value as? String else { return .failed }
            return .value(string)
        default:
            return .failed
        }
    }

    private static func integerAttribute(_ attribute: CFString,
                                         of element: AXUIElement) -> Int? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber else { return nil }
        let integer = number.intValue
        return integer >= 0 ? integer : nil
    }

    private static func rangeAttribute(_ attribute: CFString,
                                       of element: AXUIElement) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let raw = value,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private static func booleanAttribute(_ attribute: CFString,
                                         of element: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func isEditable(_ element: AXUIElement) -> Bool? {
        // Several editors expose a direct AXEditable boolean. If present, it is more
        // precise than cursor/range mutability (read-only documents can still have a
        // movable selection range).
        if let explicit = booleanAttribute("AXEditable" as CFString, of: element) {
            return explicit
        }
        var valueSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &valueSettable)
        return editableStatus(explicit: nil,
                              settableQuerySucceeded: result == .success,
                              valueSettable: valueSettable.boolValue)
    }

    private static func editableStatus(explicit: Bool?,
                                       settableQuerySucceeded: Bool,
                                       valueSettable: Bool) -> Bool? {
        if let explicit { return explicit }
        // AXValue-settable is a useful positive capability signal, but `false` only
        // describes that one AX attribute. Rich-text/web/document editors may mutate
        // through selection replacement or descendants, so it cannot prove read-only.
        return settableQuerySucceeded && valueSettable ? true : nil
    }

    private static func roleCategory(role: String, subrole: String?) -> String {
        if subrole == (kAXSearchFieldSubrole as String) { return "search_field" }
        switch role {
        case "AXTextField": return "text_field"
        case "AXTextArea": return "text_area"
        case "AXWebArea": return "web_area"
        case "AXDocument": return "document"
        default: return "other"
        }
    }

    private static func progressBucket(_ offset: Int?, total: Int?) -> Int? {
        guard let offset, let total, total > 0, offset >= 0 else { return nil }
        let bounded = min(offset, total)
        return min(20, max(0, Int((Double(bounded) / Double(total) * 20).rounded())))
    }

    nonisolated private static func safeRangeEnd(_ range: CFRange) -> Int? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let end = range.location.addingReportingOverflow(range.length)
        return end.overflow ? nil : end.partialValue
    }

    nonisolated private static func completionIsCurrent(requestRevision: UInt64,
                                                        currentRevision: UInt64) -> Bool {
        requestRevision == currentRevision
    }

    private static func isSecureSubrole(_ subrole: String?) -> Bool {
        subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func subroleDecision(for probe: AXStringProbe) -> SubroleDecision {
        switch probe {
        case .value(let value) where isSecureSubrole(value): return .secure
        case .value(let value): return .proceed(value)
        case .absent: return .proceed(nil)
        case .failed: return .failClosed
        }
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let two = String(language.prefix(2)).lowercased()
        guard two.count == 2,
              two.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) }),
              two != "un" else { return nil }
        return two
    }

    private static func localFileURL(_ raw: String) -> URL? {
        guard let identity = nonEmpty(raw) else { return nil }
        if identity.hasPrefix("/") { return URL(fileURLWithPath: identity) }
        guard let parsed = URL(string: identity), parsed.isFileURL else { return nil }
        return parsed
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func contextSignature(_ payload: AccessibilityContextPayload) -> String {
        var pieces: [String] = []
        pieces.append(payload.app ?? "-")
        pieces.append(payload.docID ?? "-")
        pieces.append(payload.documentExtension ?? "-")
        pieces.append(payload.focusedRole)
        pieces.append(payload.editable.map { $0 ? "1" : "0" } ?? "-")
        pieces.append(payload.language ?? "-")
        pieces.append(payload.langConfidence.map { String($0) } ?? "-")
        pieces.append(String(payload.sampleCharCount))
        pieces.append(payload.readStrategy)
        pieces.append(payload.caretBucket.map { String($0) } ?? "-")
        pieces.append(payload.visibleStartBucket.map { String($0) } ?? "-")
        pieces.append(payload.visibleEndBucket.map { String($0) } ?? "-")
        return pieces.joined(separator: "|")
    }

    private func publishSelection(_ payload: SelectionPayload) {
        guard !isSuspended else { return }
        bus?.publish(.live(kind: .selection, selection: payload))
    }

#if THESIS_STUDY_BUILD
    /// Pure seams for the Golden suite / diagnostics; no AX grant or live app needed.
    static func accessibilityContextHelpersCheckForTesting() -> (passed: Bool, detail: String) {
        let buckets = progressBucket(0, total: 100) == 0
            && progressBucket(50, total: 100) == 10
            && progressBucket(100, total: 100) == 20
            && progressBucket(150, total: 100) == 20
            && progressBucket(1, total: 0) == nil
        let extensions = allowedDocumentExtensions.contains("docx")
            && !allowedDocumentExtensions.contains("exe")
        let languages = normalizedLanguage("de-DE") == "de"
            && normalizedLanguage("und") == nil
        let range = boundedAXRange(CFRange(location: 100, length: 9_000),
                                   total: 12_000, centeredAt: 5_000)
        let bounded = range?.length == maximumSampleChars
        let overflowRejected = safeRangeEnd(
            CFRange(location: Int.max - 2, length: 10)) == nil
            && boundedAXRange(CFRange(location: Int.max - 2, length: 10),
                              total: nil, centeredAt: nil) == nil
        let valueReadBounds = !mayReadWholeValue(nil, role: "text_area")
            && mayReadWholeValue(maximumWholeValueChars, role: "text_area")
            && !mayReadWholeValue(maximumWholeValueChars + 1, role: "text_area")
            && !mayReadWholeValue(10, role: "web_area")
        let secureBoundary = isSecureSubrole(kAXSecureTextFieldSubrole as String)
            && !isSecureSubrole(nil)
        let staleCompletion = completionIsCurrent(requestRevision: 7, currentRevision: 7)
            && !completionIsCurrent(requestRevision: 7, currentRevision: 8)
        let revisionInvalidation = ReadTrigger.focus.invalidatesInFlightRead
            && ReadTrigger.selection.invalidatesInFlightRead
            && ReadTrigger.value.invalidatesInFlightRead
            && ReadTrigger.layout.invalidatesInFlightRead
            && ReadTrigger.scroll.invalidatesInFlightRead
            && !ReadTrigger.initial.invalidatesInFlightRead
            && !ReadTrigger.fallback.invalidatesInFlightRead
        let subroleGate: Bool = {
            guard case .proceed("AXStandardSubrole") = subroleDecision(
                for: .value("AXStandardSubrole")),
                  case .secure = subroleDecision(
                    for: .value(kAXSecureTextFieldSubrole as String)),
                  case .proceed(nil) = subroleDecision(for: .absent),
                  case .failClosed = subroleDecision(for: .failed) else { return false }
            return true
        }()
        let editability = editableStatus(explicit: false,
                                          settableQuerySucceeded: false,
                                          valueSettable: true) == false
            && editableStatus(explicit: true,
                              settableQuerySucceeded: false,
                              valueSettable: false) == true
            && editableStatus(explicit: nil,
                              settableQuerySucceeded: true,
                              valueSettable: true) == true
            && editableStatus(explicit: nil,
                              settableQuerySucceeded: true,
                              valueSettable: false) == nil
            && editableStatus(explicit: nil,
                              settableQuerySucceeded: false,
                              valueSettable: true) == nil
        let passed = buckets && extensions && languages && bounded
            && overflowRejected && valueReadBounds && secureBoundary && editability
            && staleCompletion && revisionInvalidation && subroleGate
        return (passed,
                "buckets=\(buckets), extensions=\(extensions), "
                    + "languages=\(languages), bounded_range=\(bounded), "
                    + "overflow=\(overflowRejected), value_bounds=\(valueReadBounds), "
                    + "secure=\(secureBoundary), editability=\(editability), "
                    + "stale_completion=\(staleCompletion), "
                    + "revision_invalidation=\(revisionInvalidation), "
                    + "subrole_gate=\(subroleGate)")
    }
#endif
}

/// Bare C callback required by AXObserver. Its source is installed on the running
/// main CFRunLoop; it performs no AX call and only routes a small notification label
/// through a weak integer-token registry into the sensor's debounce scheduler.
private func selectionSensorAXObserverCallback(_ observer: AXObserver,
                                               _ element: AXUIElement,
                                               _ notification: CFString,
                                               _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tokenID = UInt(bitPattern: refcon)
    let notificationName = notification as String
    MainActor.assumeIsolated {
        SelectionSensor.receiveAXNotification(tokenID: tokenID,
                                              notification: notificationName)
    }
}
