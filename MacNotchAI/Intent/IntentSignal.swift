import Foundation
import Combine

// THESIS (Computational Intent Pipeline, L1) — see docs/thesis/ARCHITECTURE.md.
//
// Event model + SignalBus. Two invariants every sensor and consumer must honour:
//
//  1. PRIVACY — raw content never crosses the bus. Sensors compute content-derived
//     scalars AT CAPTURE TIME and discard the content itself. NB: what remains
//     (hashes, embeddings, app identities, timing) is content-MINIMISED behavioural
//     data — pseudonymous, NOT anonymous: embeddings are partially invertible and
//     hashes support membership tests. It stays on-device; export only through the
//     M5 consent flow (ARCHITECTURE §4).
//
//  2. REPLAY — every event carries its own timestamp `t`. Downstream logic must use
//     event time, never Date()/wall clock. Sensors stamp at PUBLISH time, so bus
//     time is monotonic (the DEBUG tripwire below guards this). This is what makes
//     recorded traces replay deterministically through the whole pipeline (golden
//     traces = regression tests for intent detection).

// MARK: - Event model

enum SignalKind: String, Codable {
    case clipboard, contextBoundary, appFocus, scrollBurst, dwell, selection
    case accessibilityContext, activity
}

/// A content-free ownership boundary for mutable objects that other evidence points
/// at. Recording the boundary keeps live and replay state identical even when the new
/// pasteboard object is privacy-gated, or an AX target changes before its next bounded
/// read completes. It deliberately carries no content, title, path, role, or hash.
struct ContextBoundaryPayload: Codable {
    /// "pasteboard" | "accessibility_target"
    let scope: String
    /// Focused bundle for an Accessibility boundary; nil for pasteboard ownership.
    let app: String?
}

/// The participant went idle or came back (ActivityMonitor). Carries NO evidence —
/// it is segmentation metadata, so that analysis can separate work time from
/// awake-but-untouched time, and so `dense_dwell` can be told apart from "away from
/// the desk" after the fact.
struct ActivityPayload: Codable {
    /// Lifecycle/segmentation state. Current writers use `inactive`,
    /// `extended_inactivity`, `active`, `paused`, `resumed`, `sleep`, and `wake`.
    /// Kept as a String so future markers remain backwards-compatible.
    let state: String
    /// For "idle": how long input had already been absent when we noticed.
    /// For "active": how long the idle span that just ended lasted.
    let seconds: Double
}

/// A copy/cut landed on the general pasteboard. Content is classified and discarded.
struct ClipboardPayload: Codable {
    /// "text" | "url" | "image" | "files" | "other"
    let contentClass: String
    let charCount: Int
    let wordCount: Int
    /// BCP-47-ish top language guess ("de", "en", …) — nil for non-text.
    let language: String?
    let langConfidence: Double?
    /// Top language is confidently not one of the user's preferred languages.
    let isForeignLanguage: Bool
    /// "prose" | "code" | "table" | "list" | "question" | "fragment" | "" (non-text)
    let shape: String
    let hasURL: Bool
    /// First 16 hex chars of SHA-256 — re-copy/dedup detection without content.
    let hashPrefix: String
    /// Bundle id of the frontmost app at copy time (best-effort source attribution).
    let sourceApp: String?
    /// Lowercased path extensions when contentClass == "files".
    let fileExtensions: [String]?
    /// On-device sentence embedding (NLEmbedding), rounded — derived data, safe to
    /// persist. Feeds the `topic_coherence` detector. nil when unavailable.
    var embedding: [Double]? = nil
}

/// A text selection (or translator-context flip) read via the Accessibility API.
/// M2, opt-in — the ONLY permission-gated sensor (ARCHITECTURE §3). Raw selection,
/// window title, and document path are classified at capture and discarded.
struct SelectionPayload: Codable {
    let app: String?
    let charCount: Int
    let wordCount: Int
    let language: String?
    let langConfidence: Double?
    let isForeignLanguage: Bool
    let shape: String
    /// Hash prefix of the selected text (repeat-selection detection).
    let hashPrefix: String
    /// Hash prefix of document path / window title — same-document identity
    /// without storing the document. nil when the app exposes neither.
    let docID: String?
    /// Focused window looks like a translator (deepl/translate/dict…) — computed
    /// from the title AT CAPTURE, title itself is discarded.
    let isTranslatorContext: Bool
}

/// A content-minimised observation of the currently focused Accessibility target.
/// The sensor may transiently inspect an AX document path or a bounded text sample,
/// but only this derived contract may cross the bus: no text, path, file name, window
/// title, AX description, identifier, or absolute character offset is representable.
struct AccessibilityContextPayload: Codable {
    /// Bundle identifier of the focused app (best effort).
    let app: String?
    /// First 16 hex chars of the document-identity hash; never the document path/title.
    let docID: String?
    /// Lowercase extension without a leading dot, from an intentionally bounded field.
    let documentExtension: String?
    /// "text_field" | "text_area" | "search_field" | "web_area" | "document" | "other"
    let focusedRole: String
    /// true/false only when AX answered authoritatively; nil means unsupported,
    /// timed out, or otherwise unknown and must not be analysed as read-only.
    let editable: Bool?
    /// BCP-47-ish top language guess for the bounded local sample.
    let language: String?
    let langConfidence: Double?
    /// Number of characters actually classified, never the full document length.
    let sampleCharCount: Int
    /// "document_file" | "visible_range" | "value" | "range_metadata" | "none"
    let readStrategy: String
    /// Rounded progress buckets only. Absolute AX offsets never cross the bus.
    let caretBucket: Int?
    let visibleStartBucket: Int?
    let visibleEndBucket: Int?
    /// "initial" | "focus" | "selection" | "value" | "layout" | "scroll" | "fallback"
    let trigger: String
}

/// The frontmost application changed.
struct AppFocusPayload: Codable {
    let bundleID: String
    let appName: String
    /// Coarse category ("browser", "editor", "pdf", "mail", "translator", …, "other").
    let category: String
    let previousBundleID: String?
    /// How long the previous app held focus.
    let secondsInPrevious: Double?
    /// `activated` is a real switch, `baseline` opens a capture segment, and
    /// `segment_end` closes one at a lifecycle boundary. Nil means a legacy switch.
    var transition: String? = nil
}

/// A contiguous scroll gesture (events closer than 0.8 s), aggregated at burst end.
/// Direction changes are the raw material of the M2 `re_reading` detector.
struct ScrollBurstPayload: Codable {
    let app: String?
    let duration: Double
    let netDeltaY: Double
    let totalAbsDeltaY: Double
    let directionChanges: Int
}

/// The mouse was stationary for at least 10 s (emitted when movement resumes).
/// Mouse-quiet is emitted only when the OS reports no key-down during the interval;
/// it remains coarse context rather than proof that the participant was reading.
struct DwellPayload: Codable {
    let app: String?
    let seconds: Double
}

/// One observation on the bus. Exactly one payload is non-nil, matching `kind`.
/// Flat optional payloads (rather than an enum with associated values) keep the
/// JSONL schema forgiving: unknown/extra fields never break a decode.
struct SignalEvent: Codable {
    /// Ordering/decay timestamp. Live initialisers use process uptime; legacy/replayed
    /// events retain their recorded `t` unchanged.
    let t: TimeInterval
    let kind: SignalKind
    /// Explicit dual-clock capture. Nil only when decoding legacy v1/v2 traces.
    let wallTime: TimeInterval?
    let uptime: TimeInterval?
    let sessionID: String?
    let processID: Int32?
    let clockDiscontinuity: MonotonicClock.Discontinuity?
    var clipboard: ClipboardPayload? = nil
    var contextBoundary: ContextBoundaryPayload? = nil
    var appFocus: AppFocusPayload? = nil
    var scroll: ScrollBurstPayload? = nil
    var dwell: DwellPayload? = nil
    var selection: SelectionPayload? = nil
    var accessibilityContext: AccessibilityContextPayload? = nil
    var activity: ActivityPayload? = nil

    /// Explicit timestamp construction for golden checks, synthetic traces, and
    /// compatibility code. It preserves `t` exactly and intentionally has no live
    /// process-clock metadata. Runtime producers must use `live(...)` below.
    init(t: TimeInterval, kind: SignalKind,
         clipboard: ClipboardPayload? = nil,
         contextBoundary: ContextBoundaryPayload? = nil,
         appFocus: AppFocusPayload? = nil,
         scroll: ScrollBurstPayload? = nil,
         dwell: DwellPayload? = nil,
         selection: SelectionPayload? = nil,
         accessibilityContext: AccessibilityContextPayload? = nil,
         activity: ActivityPayload? = nil) {
        self.t = t
        self.kind = kind
        self.wallTime = nil
        self.uptime = nil
        self.sessionID = nil
        self.processID = nil
        self.clockDiscontinuity = nil
        self.clipboard = clipboard
        self.contextBoundary = contextBoundary
        self.appFocus = appFocus
        self.scroll = scroll
        self.dwell = dwell
        self.selection = selection
        self.accessibilityContext = accessibilityContext
        self.activity = activity
    }

    /// Runtime construction from one and only one dual-clock observation. `t` and
    /// `uptime` are therefore identical, while wall time and any discontinuity belong
    /// to that exact same signal snapshot.
    static func live(kind: SignalKind,
                     clipboard: ClipboardPayload? = nil,
                     contextBoundary: ContextBoundaryPayload? = nil,
                     appFocus: AppFocusPayload? = nil,
                     scroll: ScrollBurstPayload? = nil,
                     dwell: DwellPayload? = nil,
                     selection: SelectionPayload? = nil,
                     accessibilityContext: AccessibilityContextPayload? = nil,
                     activity: ActivityPayload? = nil) -> SignalEvent {
        let stamp = MonotonicClock.stamp()
        return SignalEvent(stamp: stamp, kind: kind, clipboard: clipboard,
                           contextBoundary: contextBoundary,
                           appFocus: appFocus, scroll: scroll, dwell: dwell,
                           selection: selection, accessibilityContext: accessibilityContext,
                           activity: activity)
    }

    private init(stamp: MonotonicClock.Stamp, kind: SignalKind,
                 clipboard: ClipboardPayload?,
                 contextBoundary: ContextBoundaryPayload?,
                 appFocus: AppFocusPayload?,
                 scroll: ScrollBurstPayload?, dwell: DwellPayload?,
                 selection: SelectionPayload?,
                 accessibilityContext: AccessibilityContextPayload?,
                 activity: ActivityPayload?) {
        t = stamp.uptime
        self.kind = kind
        wallTime = stamp.wallTime
        uptime = stamp.uptime
        sessionID = stamp.sessionID
        processID = stamp.processID
        clockDiscontinuity = stamp.discontinuity
        self.clipboard = clipboard
        self.contextBoundary = contextBoundary
        self.appFocus = appFocus
        self.scroll = scroll
        self.dwell = dwell
        self.selection = selection
        self.accessibilityContext = accessibilityContext
        self.activity = activity
    }

    private enum CodingKeys: String, CodingKey {
        case t, kind, wallTime, uptime, sessionID, processID, clockDiscontinuity
        case clipboard, contextBoundary, appFocus, scroll, dwell, selection
        case accessibilityContext, activity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(TimeInterval.self, forKey: .t)
        kind = try c.decode(SignalKind.self, forKey: .kind)
        wallTime = try c.decodeIfPresent(TimeInterval.self, forKey: .wallTime)
        uptime = try c.decodeIfPresent(TimeInterval.self, forKey: .uptime)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        processID = try c.decodeIfPresent(Int32.self, forKey: .processID)
        clockDiscontinuity = try c.decodeIfPresent(MonotonicClock.Discontinuity.self,
                                                    forKey: .clockDiscontinuity)
        clipboard = try c.decodeIfPresent(ClipboardPayload.self, forKey: .clipboard)
        contextBoundary = try c.decodeIfPresent(
            ContextBoundaryPayload.self, forKey: .contextBoundary)
        appFocus = try c.decodeIfPresent(AppFocusPayload.self, forKey: .appFocus)
        scroll = try c.decodeIfPresent(ScrollBurstPayload.self, forKey: .scroll)
        dwell = try c.decodeIfPresent(DwellPayload.self, forKey: .dwell)
        selection = try c.decodeIfPresent(SelectionPayload.self, forKey: .selection)
        accessibilityContext = try c.decodeIfPresent(
            AccessibilityContextPayload.self, forKey: .accessibilityContext)
        activity = try c.decodeIfPresent(ActivityPayload.self, forKey: .activity)
    }
}

// MARK: - SignalBus

/// The spine of the pipeline: sensors publish, consumers subscribe.
/// Also keeps a short ring buffer for windowed feature extraction (L2, M2).
final class SignalBus {

    /// Live stream. Subscribers: TraceRecorder (M1), FeatureExtractor (M2).
    let events = PassthroughSubject<SignalEvent, Never>()

    /// Recent-events window for L2 detectors. Trimmed against the NEWEST event's
    /// timestamp — not wall clock — so replayed traces window identically (§4).
    private(set) var buffer: [SignalEvent] = []

    private let windowSeconds: TimeInterval = 120
    private let capacity = 600
    private var lastPublishedT: TimeInterval = -.infinity
    /// `PassthroughSubject.send` is synchronous and permits re-entrant sends. Without
    /// this queue, subscriber A can publish a newer event while subscriber B has not
    /// received the outer event yet, so B observes t2 before t1. That is fatal for the
    /// append-only trace. One outer publisher therefore drains every nested publish in
    /// strict FIFO order only after all subscribers saw the preceding event.
    private var pendingEvents: [SignalEvent] = []
    private var isDrainingEvents = false

    func publish(_ event: SignalEvent) {
        pendingEvents.append(event)
        guard !isDrainingEvents else { return }

        isDrainingEvents = true
        defer {
            pendingEvents.removeAll(keepingCapacity: true)
            isDrainingEvents = false
        }

        var index = 0
        while index < pendingEvents.count {
            deliver(pendingEvents[index])
            index += 1
        }
    }

    private func deliver(_ event: SignalEvent) {
#if DEBUG
        // Monotonicity tripwire: sensors stamp at publish time, so time can never
        // run backwards on the bus. If this prints, a sensor regressed to stamping
        // past timestamps — fix the sensor, don't relax the invariant.
        if event.t < lastPublishedT - 0.001 {
            print("[intent] ⚠️ non-monotonic publish: \(event.kind.rawValue) " +
                  "t=\(event.t) < last=\(lastPublishedT)")
        }
#endif
        lastPublishedT = max(lastPublishedT, event.t)
        buffer.append(event)
        let cutoff = event.t - windowSeconds
        if buffer.first.map({ $0.t < cutoff }) == true {
            buffer.removeAll { $0.t < cutoff }
        }
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        events.send(event)
    }

#if THESIS_STUDY_BUILD
    /// Isolated deterministic seam used by the Study golden checks. The second sink
    /// represents the recorder: it must see the outer event before a nested publish.
    static func reentrantDeliveryCheckForTesting() -> Bool {
        let bus = SignalBus()
        var firstSink: [TimeInterval] = []
        var recorderSink: [TimeInterval] = []
        var subscriptions: [AnyCancellable] = []

        subscriptions.append(bus.events.sink { event in
            firstSink.append(event.t)
            if event.t == 1 {
                bus.publish(SignalEvent(t: 2, kind: .activity,
                                        activity: ActivityPayload(state: "active", seconds: 0)))
            }
        })
        subscriptions.append(bus.events.sink { recorderSink.append($0.t) })
        bus.publish(SignalEvent(t: 1, kind: .activity,
                                activity: ActivityPayload(state: "active", seconds: 0)))

        return firstSink == [1, 2]
            && recorderSink == [1, 2]
            && bus.buffer.map(\.t) == [1, 2]
            && subscriptions.count == 2
    }
#endif

    /// Full wipe — required before replaying a trace: stale live events carry
    /// timestamps FAR ahead of the recorded timeline and would corrupt windowing.
    func reset() {
        buffer = []
        lastPublishedT = -.infinity
    }

    /// Events within `seconds` before the reference time (defaults to newest event).
    func recent(within seconds: TimeInterval, before reference: TimeInterval? = nil) -> [SignalEvent] {
        guard let newest = reference ?? buffer.last?.t else { return [] }
        return buffer.filter { $0.t > newest - seconds && $0.t <= newest }
    }
}

// MARK: - Sensor protocol

protocol IntentSensor: AnyObject {
    var name: String { get }
    func start(bus: SignalBus)
    /// Attach to the bus without emitting or arming an event source. Used when a
    /// persisted participant pause survives relaunch.
    func startSuspended(bus: SignalBus)
    func stop()

    /// Pause periodic work while the participant is away (ActivityMonitor). Distinct
    /// from `stop()`: the sensor keeps its state and its subscription, it just stops
    /// spending wake-ups on a machine nobody is using. Event-driven sensors need no
    /// implementation — hence the default no-ops.
    func suspend()
    func resume()
}

extension IntentSensor {
    func startSuspended(bus: SignalBus) {
        start(bus: bus)
        suspend()
    }
}

extension IntentSensor {
    func suspend() {}
    func resume() {}
}
