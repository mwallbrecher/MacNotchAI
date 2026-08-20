import AppKit

// THESIS (L1 sensor) — clipboard observation via changeCount polling.
//
// Same ungated mechanism as ClipboardHistoryStore, but deliberately independent:
// the history store is a user-facing feature with its own settings/lifecycle on
// main; this sensor must keep working (and merging) regardless of what happens
// to that feature. Polling an Int at 2 Hz is negligible.
//
// PRIVACY: the pasteboard string is classified (IntentText) and discarded — only
// derived scalars are published. Sensitive pasteboards (PasteboardPrivacy) publish
// only the same content-free ownership boundary as every other change; no type,
// source, hash, or content-derived value from the replacement is recorded.
final class ClipboardSensor: IntentSensor {

    let name = "clipboard"

    private weak var bus: SignalBus?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var previousFrontmostBundleID: String?

    func start(bus: SignalBus) {
        self.bus = bus
        resume()
    }

    private func armObservation(resetBaseline: Bool = true) {
        if resetBaseline {
            lastChangeCount = NSPasteboard.general.changeCount   // ignore pre-existing content
        }
        previousFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // .common mode: default-mode timers pause during menu tracking (repo idiom).
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Tolerance lets macOS coalesce this wake-up with other system activity so the
        // CPU can stay in a deep idle state between clusters. On a 13-day in-situ
        // deployment that is the single largest energy lever, and it costs nothing:
        // every event carries its own timestamp, so a late poll is not a lost one.
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        suspend()
        bus = nil
    }

    /// Preserve a pasteboard change that happened inside the current app-focus
    /// segment but has not reached the 0.5-second poll yet. Safe to call repeatedly:
    /// `processChange` advances `lastChangeCount` before it publishes.
    func flushBeforeGap() {
        flushPendingChange()
    }

    /// Reconcile a copy before a same-process AX document/window boundary is written.
    /// This binds the copy to the source object segment instead of whichever document
    /// happens to be focused at the next 0.5-second poll.
    func flushPendingChange() {
        guard timer != nil else { return }
        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount {
            processChange(on: pb, sourceApp: previousFrontmostBundleID)
        }
    }

    /// Idle: nobody is copying anything, so stop polling. On resume the changeCount
    /// baseline is re-read, so a copy made by another process while we slept is not
    /// mistaken for a fresh user copy — a copy is only an intent signal when it is a
    /// deliberate act, and we cannot attribute one we did not observe.
    func suspend() {
        // A lifecycle boundary may arrive inside the 0.5 s polling interval. Preserve
        // a copy that happened before that boundary instead of silently dropping it.
        // Source attribution still uses the last observed frontmost application.
        flushBeforeGap()
        timer?.invalidate()
        timer = nil
        previousFrontmostBundleID = nil
        IntentContentVault.shared.clear()
    }

    func resume() {
        guard timer == nil, let bus else { return }
        self.bus = bus
        armObservation()
    }

    /// Extended-inactivity wake is different from pause/sleep: the wake detector has
    /// just observed fresh human input, so one pasteboard change since gating is a
    /// attributable first action rather than stale background state. Publish it after
    /// the engine's `active` marker, then re-arm normal polling. Manual pause and sleep
    /// continue to call `resume()` and therefore intentionally discard their changes.
    func resumeAfterExtendedInactivity() {
        guard timer == nil, let bus else { return }
        self.bus = bus
        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount {
            processChange(on: pb,
                          sourceApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        armObservation(resetBaseline: false)
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        processChange(on: pb,
                      sourceApp: previousFrontmostBundleID
                          ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Observe a pending pasteboard change before advancing the frontmost-app
    /// baseline. This preserves both source attribution and copy→switch event order
    /// when the participant changes apps faster than the 0.5 s polling interval.
    /// Called synchronously by AppFocusSensor's single workspace observer before it
    /// publishes the corresponding focus transition. Keeping that sequence in one
    /// observer avoids relying on NotificationCenter observer-registration order.
    func prepareForAppActivation(bundleID: String) {
        guard timer != nil else { return }
        guard bundleID != previousFrontmostBundleID else { return }

        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount {
            processChange(on: pb, sourceApp: previousFrontmostBundleID)
        }
        previousFrontmostBundleID = bundleID
    }

    private func processChange(on pb: NSPasteboard, sourceApp: String?) {
        lastChangeCount = pb.changeCount
        // The boundary is part of the trace, not a RAM-only side channel. Replay can
        // therefore retract the exact same object-bound evidence even when privacy or
        // unsupported content prevents a following clipboard payload.
        bus?.publish(.live(
            kind: .contextBoundary,
            contextBoundary: ContextBoundaryPayload(scope: "pasteboard", app: nil)))

        let types = pb.types ?? []
        // Shared privacy gate (PasteboardPrivacy — the SAME list ClipboardHistoryStore
        // uses, so the two clipboard paths cannot drift): concealed / is-sensitive /
        // transient / auto-generated content never enters the pipeline in any derived
        // form. Auto-generated is also semantic hygiene — a programmatic pasteboard
        // write is not a user copy, hence not a content signal. Its content-free
        // ownership boundary above is retained solely to invalidate older aliases.
        guard !PasteboardPrivacy.isSensitive(types) else {
            IntentContentVault.shared.clear()
            return
        }

        guard let classified = classify(pb, types: types, sourceApp: sourceApp) else { return }
        let t = MonotonicClock.now
        if let rawText = classified.rawText {
            IntentContentVault.shared.store(text: rawText,
                                            hash: classified.payload.hashPrefix,
                                            at: t)
        }
        bus?.publish(.live(kind: .clipboard, clipboard: classified.payload))
    }

    // MARK: Classification (content in, scalars out, content dropped)

    private struct ClassifiedClipboard {
        let payload: ClipboardPayload
        /// RAM-only handoff to IntentContentVault. Never published or encoded.
        let rawText: String?
    }

    private func classify(_ pb: NSPasteboard,
                          types: [NSPasteboard.PasteboardType],
                          sourceApp: String?) -> ClassifiedClipboard? {
        // Files first — a Finder copy also carries a string representation.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return ClassifiedClipboard(payload: ClipboardPayload(
                contentClass: "files", charCount: 0, wordCount: 0,
                language: nil, langConfidence: nil, isForeignLanguage: false,
                shape: "", hasURL: false,
                hashPrefix: IntentText.hashPrefix(urls.map(\.path).joined(separator: "\n")),
                sourceApp: sourceApp,
                fileExtensions: urls.map { $0.pathExtension.lowercased() }), rawText: nil)
        }

        if let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {

            // Whole-string URL ⇒ its own content class (link drops are their own world).
            let isWholeURL = !text.contains(" ")
                && (text.hasPrefix("http://") || text.hasPrefix("https://"))
                && URL(string: text) != nil
            if isWholeURL {
                return ClassifiedClipboard(payload: ClipboardPayload(
                    contentClass: "url", charCount: text.count, wordCount: 1,
                    language: nil, langConfidence: nil, isForeignLanguage: false,
                    shape: "", hasURL: true,
                    hashPrefix: IntentText.hashPrefix(text),
                    sourceApp: sourceApp, fileExtensions: nil), rawText: nil)
            }

            let s = IntentText.scalars(for: text)
            return ClassifiedClipboard(payload: ClipboardPayload(
                contentClass: "text",
                charCount: s.charCount, wordCount: s.wordCount,
                language: s.language, langConfidence: s.langConfidence,
                isForeignLanguage: s.isForeignLanguage,
                shape: s.shape,
                hasURL: text.contains("http://") || text.contains("https://") || text.contains("www."),
                hashPrefix: s.hashPrefix,
                sourceApp: sourceApp, fileExtensions: nil,
                embedding: s.embedding), rawText: text)
        }

        if types.contains(.tiff) || types.contains(.png) {
            return ClassifiedClipboard(payload: ClipboardPayload(
                contentClass: "image", charCount: 0, wordCount: 0,
                language: nil, langConfidence: nil, isForeignLanguage: false,
                shape: "", hasURL: false, hashPrefix: "",
                sourceApp: sourceApp, fileExtensions: nil), rawText: nil)
        }

        return nil   // nothing we understand — emit nothing rather than noise
    }
}
