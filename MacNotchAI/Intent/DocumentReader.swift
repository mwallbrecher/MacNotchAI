import AppKit
import ApplicationServices

// THESIS (L4 support) — bounded, accept-time-verifiable AX access for the object the
// participant is looking at. Product paths capture the frontmost-app coordinates on
// MainActor and perform every synchronous cross-process AX call on a utility task.
enum DocumentReader {

    nonisolated static let minimumUsefulChars = 400
    nonisolated private static let minimumSelectionChars = 3

    // Calibrated against a real 10,000-word thesis in Microsoft Word, which exposes
    // its FULL text through AX rather than only the laid-out page: 69,482 characters
    // across 62 text nodes, 386 nodes visited, tree exactly 14 levels deep, 0.24 s for
    // a bare walk. The previous 40,000-character ceiling silently discarded 43% of
    // that document, and a depth ceiling of 14 sat exactly on the measured depth with
    // no headroom for a nested table or text box.
    //
    // The materialised text becomes an ordinary session file via DropMaterializer, so
    // the product's existing limits still govern what reaches a provider; these bounds
    // exist to keep the traversal itself predictable, not to size an AI request.
    nonisolated private static let maximumChars = 200_000
    nonisolated private static let maxDepth = 24
    nonisolated private static let maxNodes = 6_000
    /// The measured 0.24 s came from a walk issuing ~2 AX calls per node. This reader
    /// issues roughly twice that (role, subrole, value, children), so the real cost is
    /// nearer 0.5 s and the old 0.85 s budget had little margin on a loaded machine —
    /// where exceeding it truncates the document silently.
    nonisolated private static let traversalBudget: TimeInterval = 1.5

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

    enum Strategy: String {
        case focusedElement = "focused element"
        case windowWalk = "window walk"
        case windowFallback = "focused-window fallback"
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

    /// Role/subrole probes distinguish a legitimate optional absence from a transport,
    /// timeout, invalid-element, or type failure. Only the former may proceed: an
    /// ambiguous security classification must never be followed by a content read.
    private enum AXStringProbe {
        case value(String)
        case absent
        case failed
    }

    private enum ContentReadDecision {
        case proceed
        case secure
        case failClosed
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

    /// Re-reads the offered object and fails closed if the app or the document changed
    /// between ticker-show and accept.
    ///
    /// How much more than identity has to match depends on the scope, because the two
    /// scopes make different claims. A SELECTION is a precise statement — "these exact
    /// words" — so it must still match byte for byte: a selection whose content moved
    /// is a different object, and substituting it would betray what was offered. A
    /// DOCUMENT claims "the thing you are working in", and that claim survives editing.
    /// Demanding byte equality there would reject every offer the participant kept
    /// typing through, which in a writing task is very nearly all of them, and would
    /// record the resulting `materialize_failed` as if the participant had changed
    /// their mind. Identity — same process, same bundle, same AXDocument — is what must
    /// hold; the content is then read fresh at accept.
    @MainActor
    static func read(matching snapshot: Snapshot) async -> String? {
        guard !requestInFlight, AXIsProcessTrusted(), let front = frontContext(),
              front.pid == snapshot.pid,
              front.bundleID == snapshot.bundleID else { return nil }

        requestInFlight = true
        defer { requestInFlight = false }
        return await Task.detached(priority: .userInitiated) {
            guard let raw = readScope(snapshot.scope, front: front),
                  raw.docID == snapshot.docID else { return nil }
            if requiresExactContent(scope: snapshot.scope, docID: snapshot.docID) {
                guard raw.text.count == snapshot.charCount,
                      IntentText.hashPrefix(raw.text) == snapshot.contentHash else { return nil }
            }
            return String(raw.text.prefix(maximumChars))
        }.value
    }

    /// Pure accept-time contract, kept separate so it is checkable without a live AX
    /// grant. A selection must match byte for byte; an identified document may have
    /// been edited since it was offered. Without a document identity there is nothing
    /// to anchor "same document" on — a switch to another file inside the same app
    /// would be invisible — so that case stays strict.
    nonisolated static func requiresExactContent(scope: Scope, docID: String?) -> Bool {
        scope == .selection || docID == nil
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
        // A read landing on the ceiling was almost certainly cut short. Coverage
        // numbers are worthless if truncation stays invisible inside them.
        let capped = raw.text.count >= maximumChars
        return Diagnosis(appName: name, axTrusted: true, charCount: raw.text.count,
                         strategy: raw.strategy,
                         verdict: enough
                            ? (capped
                                ? "CAPPED at \(maximumChars) chars — document is larger"
                                : "OK — document actions will be offered")
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
        let mayRetry = requestFullAccessibility(for: front.pid, bundleID: front.bundleID)
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

        // Every content path below starts from an element whose role/subrole can be
        // classified. When no such element exists, only whole-document scope may fall
        // back to the window — see `readFocusedWindow` for why a selection may not.
        guard let anchor = focused,
              permitsContentRead(of: anchor) else {
            guard scope == .document else { return nil }
            return readFocusedWindow(pid: pid)
        }
        let docID = documentIdentity(of: anchor)

        if scope == .selection {
            guard permitsContentRead(of: anchor) else { return nil }
            var selectionRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(anchor, kAXSelectedTextAttribute as CFString,
                                                &selectionRef) == .success,
                  let raw = selectionRef as? String else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minimumSelectionChars else { return nil }
            return RawRead(text: String(text.prefix(maximumChars)), docID: docID,
                           strategy: .focusedElement)
        }

        // No early return on a "long enough" focused element. In a paginated editor the
        // focused element is one section, not the document: a 10,000-word Word file
        // yields 3.5k characters that way and 69k from the window walk. `minimumUsefulChars`
        // is the floor for offering an action at all, never evidence that the best
        // available read has been found — the comparison below decides that.
        let own = stringValue(of: anchor)

        var root = anchor
        var windowRef: CFTypeRef?
        if permitsContentRead(of: anchor),
           AXUIElementCopyAttributeValue(anchor, kAXWindowAttribute as CFString,
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

    /// Some applications — Microsoft Word among them — expose no system-wide focused
    /// element even with enhanced accessibility raised, while their window tree reads
    /// normally. The window is resolved from the application element for the SAME
    /// verified pid, and `collectText` classifies role/subrole at every node, so a
    /// secure field anywhere in that tree still stops its own subtree from being read.
    ///
    /// Only `.document` may take this path. Without a focused element there is no
    /// evidence about which object the participant is attending to: acceptable for
    /// whole-document context, not for a selection that claims to be the one they made.
    nonisolated private static func readFocusedWindow(pid: pid_t) -> RawRead? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let ref = windowRef, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let window = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)

        guard permitsContentRead(of: window),
              let text = collectText(under: window) else { return nil }
        return RawRead(text: text, docID: documentIdentity(ofWindow: window),
                       strategy: .windowFallback)
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

            // Skip the complete subtree before AXValue *or* AXChildren when a node is
            // secure or its role/subrole cannot be classified authoritatively.
            guard permitsContentRead(of: el) else { return }

            if let own = uncheckedStringValue(of: el), own.count >= 12 {
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
        guard permitsContentRead(of: element) else { return nil }
        return uncheckedStringValue(of: element)
    }

    /// Caller has already passed `contentReadDecision`; keeping the raw AXValue read
    /// separate prevents the recursive walk from issuing duplicate role/subrole IPC.
    nonisolated private static func uncheckedStringValue(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.5)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                            &ref) == .success,
              let value = ref as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated private static func documentIdentity(of element: AXUIElement) -> String? {
        guard permitsContentRead(of: element) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.5)
        var window = element
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString,
                                         &windowRef) == .success,
           let ref = windowRef, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            window = (ref as! AXUIElement)
            AXUIElementSetMessagingTimeout(window, 0.5)
        }

        // Focus can change while synchronous AX IPC is in flight. Revalidate the
        // original focused element immediately before reading document/title context.
        guard permitsContentRead(of: element) else { return nil }
        return documentIdentity(ofWindow: window)
    }

    /// The document path is deliberately reduced to a hash: this value exists only to
    /// detect that the offered object changed between ticker-show and accept, so the
    /// path itself never has to be held.
    nonisolated private static func documentIdentity(ofWindow window: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(window, 0.5)
        var documentRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &documentRef)
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let identity = (documentRef as? String) ?? (titleRef as? String)
        return identity.map(IntentText.hashPrefix)
    }

    nonisolated private static func contentReadDecision(
        role: AXStringProbe,
        subrole: AXStringProbe
    ) -> ContentReadDecision {
        guard case .value(let roleValue) = role, !roleValue.isEmpty else {
            return .failClosed
        }
        switch subrole {
        case .value(let value) where value == (kAXSecureTextFieldSubrole as String):
            return .secure
        case .value, .absent:
            return .proceed
        case .failed:
            return .failClosed
        }
    }

    nonisolated private static func contentReadDecision(
        for element: AXUIElement
    ) -> ContentReadDecision {
        let role = stringProbe(kAXRoleAttribute as CFString, of: element)
        let subrole = stringProbe(kAXSubroleAttribute as CFString, of: element)
        return contentReadDecision(role: role, subrole: subrole)
    }

    nonisolated private static func permitsContentRead(of element: AXUIElement) -> Bool {
        if case .proceed = contentReadDecision(for: element) { return true }
        return false
    }

    nonisolated private static func matches(
        _ actual: ContentReadDecision,
        _ expected: ContentReadDecision
    ) -> Bool {
        switch (actual, expected) {
        case (.proceed, .proceed), (.secure, .secure), (.failClosed, .failClosed):
            return true
        default:
            return false
        }
    }

    nonisolated private static func stringProbe(_ attribute: CFString,
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

#if THESIS_STUDY_BUILD
    /// Pure security-contract seam: no live AX grant or foreign process is required.
    static func secureReadBoundaryCheckForTesting() -> (passed: Bool, detail: String) {
        let ordinary = matches(contentReadDecision(
            role: .value("AXTextArea"), subrole: .absent), .proceed)
        let secure = matches(contentReadDecision(
            role: .value("AXTextField"),
            subrole: .value(kAXSecureTextFieldSubrole as String)), .secure)
        let roleAbsent = matches(
            contentReadDecision(role: .absent, subrole: .absent), .failClosed)
        let roleFailed = matches(
            contentReadDecision(role: .failed, subrole: .absent), .failClosed)
        let subroleFailed = matches(contentReadDecision(
            role: .value("AXTextArea"), subrole: .failed), .failClosed)
        let wrongRoleType = matches(contentReadDecision(
            role: .value(""), subrole: .absent), .failClosed)
        let passed = ordinary && secure && roleAbsent && roleFailed
            && subroleFailed && wrongRoleType
        return (passed,
                "ordinary=\(ordinary), secure=\(secure), role_absent=\(roleAbsent), "
                    + "role_failed=\(roleFailed), subrole_failed=\(subroleFailed), "
                    + "empty_role=\(wrongRoleType)")
    }
#endif

    // MARK: Enhanced-accessibility lifecycle

    /// `AXEnhancedUserInterface` is how assistive software tells an application to
    /// expose its full tree, and it changes how that OTHER application behaves —
    /// AppKit window geometry and Chromium tree generation both react to it. A flag
    /// Dragaway raised is therefore Dragaway's to lower again. A flag that was already
    /// raised belongs to something else (VoiceOver, a window manager) and is left alone.
    ///
    /// The flag stays raised while an app is being observed rather than being toggled
    /// per read: this path runs at sensor frequency, and flapping it every tick would
    /// tear down and rebuild the target's accessibility tree continuously. Nothing
    /// survives the process — `releaseEnhancedAccessibility()` restores every app that
    /// was touched.
    private struct EnhancedUIRecord {
        /// macOS recycles pids. A different bundle under a known pid is a different app.
        let bundleID: String?
        let wasAlreadyRaised: Bool
    }

    nonisolated(unsafe) private static var enhancedUI: [pid_t: EnhancedUIRecord] = [:]
    nonisolated private static let enhancedUILock = NSLock()
    nonisolated private static let maxTrackedApps = 64

    @discardableResult
    nonisolated private static func requestFullAccessibility(for pid: pid_t,
                                                             bundleID: String?) -> Bool {
        enhancedUILock.lock()
        let known = enhancedUI[pid]
        enhancedUILock.unlock()
        // A recycled pid running a different bundle has never been prepared by us.
        guard known == nil || known?.bundleID != bundleID else { return false }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let alreadyRaised = isEnhancedUIRaised(app)
        if !alreadyRaised {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString,
                                         kCFBooleanTrue)
        }

        enhancedUILock.lock()
        pruneExitedAppsLocked()
        enhancedUI[pid] = EnhancedUIRecord(bundleID: bundleID,
                                           wasAlreadyRaised: alreadyRaised)
        enhancedUILock.unlock()
        return true
    }

    nonisolated private static func isEnhancedUIRaised(_ app: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString,
                                            &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    /// Caller holds `enhancedUILock`. An app that has exited needs no restoring, so the
    /// table cannot grow without bound across a long recording session.
    nonisolated private static func pruneExitedAppsLocked() {
        guard enhancedUI.count >= maxTrackedApps else { return }
        enhancedUI = enhancedUI.filter { pid, record in
            guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
            return running.bundleIdentifier == record.bundleID
        }
    }

    /// Lowers every flag Dragaway raised, so no application is left in enhanced
    /// accessibility mode once observation stops. Safe to call more than once.
    nonisolated static func releaseEnhancedAccessibility() {
        enhancedUILock.lock()
        let tracked = enhancedUI
        enhancedUI.removeAll()
        enhancedUILock.unlock()

        for (pid, record) in tracked where !record.wasAlreadyRaised {
            guard let running = NSRunningApplication(processIdentifier: pid),
                  running.bundleIdentifier == record.bundleID else { continue }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString,
                                         kCFBooleanFalse)
        }
    }
}
