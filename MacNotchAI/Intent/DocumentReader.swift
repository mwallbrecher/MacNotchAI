import AppKit
import ApplicationServices

// THESIS (L4 support) — bounded, accept-time-verifiable AX access for the object the
// participant is looking at. Product paths capture the frontmost-app coordinates on
// MainActor and perform every synchronous cross-process AX call on a utility task.
enum DocumentReader {

    nonisolated static let minimumUsefulChars = 400
    nonisolated private static let minimumSelectionChars = 3
    nonisolated private static let maximumChars = 40_000
    nonisolated private static let maxDepth = 14
    nonisolated private static let maxNodes = 6_000
    nonisolated private static let traversalBudget: TimeInterval = 0.85

    /// AX calls cannot be cancelled once another process is servicing them. Keep one
    /// request in flight across probe and accept-time verification so rapid summon
    /// close/reopen gestures cannot accumulate detached accessibility traversals.
    @MainActor private static var requestInFlight = false

    enum Scope: String, Sendable {
        case selection
        case document
    }

    /// Immutable coordinates of the exact object offered in the ticker. Raw text is
    /// absent; accept re-reads AX and requires every available coordinate to match.
    struct Snapshot: Sendable {
        let scope: Scope
        let pid: pid_t
        let bundleID: String?
        let appName: String?
        let docID: String?
        let contentHash: String
        let charCount: Int
    }

    struct ProbeContext: Sendable {
        let selection: Snapshot?
        let document: Snapshot?
    }

    struct Probe {
        let charCount: Int
        let docID: String?
        let appName: String?
        let strategy: Strategy
    }

    enum Strategy: String {
        case focusedElement = "focused element"
        case windowWalk = "window walk"
    }

    struct Diagnosis {
        let appName: String
        let axTrusted: Bool
        let charCount: Int
        let strategy: Strategy?
        let verdict: String
    }

    private struct FrontContext: Sendable {
        let pid: pid_t
        let bundleID: String?
        let appName: String?
    }

    private struct RawRead {
        let text: String
        let docID: String?
        let strategy: Strategy
    }

    // MARK: Product API

    /// Resolves the current AX selection first. The expensive document walk is only
    /// requested when the caller has no fresh clipboard fallback.
    @MainActor
    static func probe(includeDocumentFallback: Bool) async -> ProbeContext {
        guard !requestInFlight, AXIsProcessTrusted(), let front = frontContext() else {
            return ProbeContext(selection: nil, document: nil)
        }
        requestInFlight = true
        defer { requestInFlight = false }
        return await Task.detached(priority: .userInitiated) {
            readProbe(front: front, includeDocument: includeDocumentFallback)
        }.value
    }

    /// Re-reads the offered object and fails closed if the app, document, selection,
    /// content hash, or character count changed between ticker-show and accept.
    @MainActor
    static func read(matching snapshot: Snapshot) async -> String? {
        guard !requestInFlight, AXIsProcessTrusted(), let front = frontContext(),
              front.pid == snapshot.pid,
              front.bundleID == snapshot.bundleID else { return nil }

        requestInFlight = true
        defer { requestInFlight = false }
        return await Task.detached(priority: .userInitiated) {
            guard let raw = readScope(snapshot.scope, front: front),
                  raw.docID == snapshot.docID,
                  raw.text.count == snapshot.charCount,
                  IntentText.hashPrefix(raw.text) == snapshot.contentHash else { return nil }
            return String(raw.text.prefix(maximumChars))
        }.value
    }

    @MainActor
    private static func frontContext() -> FrontContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontContext(pid: app.processIdentifier,
                            bundleID: app.bundleIdentifier,
                            appName: app.localizedName)
    }

    // MARK: Debug coverage API retained for AppDelegate

    static func probeLogURL() -> URL {
        TraceRecorder.tracesDirectory().appendingPathComponent("ax-probe-results.txt")
    }

    static func appendProbeResult(_ d: Diagnosis) {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        let line = String(format: "%@  %-22@ %-46@ chars=%-7d via=%@\n",
                          stamp.string(from: Date()), d.appName, d.verdict, d.charCount,
                          d.strategy?.rawValue ?? "—")
        let url = probeLogURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            let header = "AX document-reader coverage probe\n"
                + "Threshold: \(minimumUsefulChars) readable characters\n"
                + String(repeating: "─", count: 100) + "\n"
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
            try? h.close()
        }
    }

    /// Debug-only synchronous seam used by the existing delayed menu probe. The live
    /// ticker/accept paths above never call this from MainActor.
    static func diagnose() -> Diagnosis {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "unknown"
        guard AXIsProcessTrusted() else {
            return Diagnosis(appName: name, axTrusted: false, charCount: 0, strategy: nil,
                             verdict: "no Accessibility grant — enable it, then retry")
        }
        guard let app else {
            return Diagnosis(appName: name, axTrusted: true, charCount: 0, strategy: nil,
                             verdict: "NO TEXT — no frontmost application")
        }
        let front = FrontContext(pid: app.processIdentifier,
                                 bundleID: app.bundleIdentifier,
                                 appName: app.localizedName)
        guard let raw = readScope(.document, front: front) else {
            return Diagnosis(appName: name, axTrusted: true, charCount: 0, strategy: nil,
                             verdict: "NO TEXT — app exposes nothing readable via AX")
        }
        let enough = raw.text.count >= minimumUsefulChars
        return Diagnosis(appName: name, axTrusted: true, charCount: raw.text.count,
                         strategy: raw.strategy,
                         verdict: enough
                            ? "OK — document actions will be offered"
                            : "TOO SHORT — \(raw.text.count) chars, need ≥ \(minimumUsefulChars)")
    }

    // MARK: Detached AX implementation

    nonisolated private static func readProbe(front: FrontContext,
                                               includeDocument: Bool) -> ProbeContext {
        let selectionRaw = readScope(.selection, front: front)
        let selection = selectionRaw.flatMap { raw -> Snapshot? in
            guard raw.text.count >= minimumSelectionChars else { return nil }
            return makeSnapshot(scope: .selection, raw: raw, front: front)
        }

        var document: Snapshot?
        if selection == nil, includeDocument,
           let raw = readScope(.document, front: front),
           raw.text.count >= minimumUsefulChars {
            document = makeSnapshot(scope: .document, raw: raw, front: front)
        }
        return ProbeContext(selection: selection, document: document)
    }

    nonisolated private static func makeSnapshot(scope: Scope, raw: RawRead,
                                                 front: FrontContext) -> Snapshot {
        Snapshot(scope: scope, pid: front.pid, bundleID: front.bundleID,
                 appName: front.appName, docID: raw.docID,
                 contentHash: IntentText.hashPrefix(raw.text), charCount: raw.text.count)
    }

    nonisolated private static func readScope(_ scope: Scope,
                                              front: FrontContext) -> RawRead? {
        let mayRetry = requestFullAccessibility(for: front.pid)
        if let result = readOnce(scope, pid: front.pid) { return result }
        guard mayRetry else { return nil }
        // Chromium builds its AX tree asynchronously. This wait is deliberately inside
        // the detached utility task, never on the UI/main actor.
        Thread.sleep(forTimeInterval: 0.4)
        return readOnce(scope, pid: front.pid)
    }

    nonisolated private static func readOnce(_ scope: Scope, pid: pid_t) -> RawRead? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)

        var focusedRef: CFTypeRef?
        var focused: AXUIElement?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString,
                                         &focusedRef) == .success,
           let ref = focusedRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let candidate = ref as! AXUIElement
            var candidatePID: pid_t = 0
            // The frontmost app can change between the MainActor snapshot and this
            // detached read. Never label app B's focused element with app A's PID.
            if AXUIElementGetPid(candidate, &candidatePID) == .success,
               candidatePID == pid {
                focused = candidate
                AXUIElementSetMessagingTimeout(candidate, 0.5)
            }
        }

        var anchor = focused
        if anchor == nil {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                             &windowRef) == .success,
               let ref = windowRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
                anchor = (ref as! AXUIElement)
                AXUIElementSetMessagingTimeout(anchor!, 0.5)
            }
        }
        guard let anchor else { return nil }
        let docID = documentIdentity(of: anchor)

        if scope == .selection {
            var selectionRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(anchor, kAXSelectedTextAttribute as CFString,
                                                &selectionRef) == .success,
                  let raw = selectionRef as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minimumSelectionChars else { return nil }
            return RawRead(text: String(text.prefix(maximumChars)), docID: docID,
                           strategy: .focusedElement)
        }

        let own = stringValue(of: anchor)
        if let own, own.count >= minimumUsefulChars {
            return RawRead(text: String(own.prefix(maximumChars)), docID: docID,
                           strategy: .focusedElement)
        }

        var root = anchor
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(anchor, kAXWindowAttribute as CFString,
                                         &windowRef) == .success,
           let ref = windowRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            root = (ref as! AXUIElement)
            AXUIElementSetMessagingTimeout(root, 0.5)
        }
        let walked = collectText(under: root)
        switch (own, walked) {
        case let (o?, w?):
            return o.count >= w.count
                ? RawRead(text: String(o.prefix(maximumChars)), docID: docID,
                          strategy: .focusedElement)
                : RawRead(text: w, docID: docID, strategy: .windowWalk)
        case let (o?, nil):
            return RawRead(text: String(o.prefix(maximumChars)), docID: docID,
                           strategy: .focusedElement)
        case let (nil, w?):
            return RawRead(text: w, docID: docID, strategy: .windowWalk)
        case (nil, nil):
            return nil
        }
    }

    nonisolated private static func collectText(under element: AXUIElement) -> String? {
        var pieces: [String] = []
        var total = 0
        var visited = 0
        let deadline = ProcessInfo.processInfo.systemUptime + traversalBudget

        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, visited < maxNodes, total < maximumChars,
                  ProcessInfo.processInfo.systemUptime < deadline else { return }
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.5)

            if let own = stringValue(of: el), own.count >= 12 {
                let remaining = maximumChars - total
                let bounded = String(own.prefix(remaining))
                pieces.append(bounded)
                total += bounded.count
            }

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString,
                                                &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            for child in children {
                guard visited < maxNodes, total < maximumChars,
                      ProcessInfo.processInfo.systemUptime < deadline else { return }
                walk(child, depth + 1)
            }
        }

        walk(element, 0)
        guard !pieces.isEmpty else { return nil }
        let joined = pieces.joined(separator: "\n")
        return joined.count >= 12 ? String(joined.prefix(maximumChars)) : nil
    }

    nonisolated private static func stringValue(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &ref) == .success,
              let value = ref as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated private static func documentIdentity(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var window = element
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString,
                                         &windowRef) == .success,
           let ref = windowRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            window = (ref as! AXUIElement)
            AXUIElementSetMessagingTimeout(window, 0.5)
        }

        var documentRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef)
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let identity = (documentRef as? String) ?? (titleRef as? String)
        return identity.map(IntentText.hashPrefix)
    }

    nonisolated(unsafe) private static var accessibilityRequested = Set<pid_t>()
    nonisolated private static let accessibilityLock = NSLock()

    @discardableResult
    nonisolated private static func requestFullAccessibility(for pid: pid_t) -> Bool {
        accessibilityLock.lock()
        let first = !accessibilityRequested.contains(pid)
        accessibilityRequested.insert(pid)
        accessibilityLock.unlock()

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return first
    }
}
