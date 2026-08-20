import Foundation
import Combine

// THESIS (L2) — feature detectors: typed evidence out of the raw event stream.
// See docs/thesis/ARCHITECTURE.md §8. Every detector is a small state machine over
// event-carried timestamps (never wall clock — the replay invariant).
//
// M2 implements the original detector set plus two content-minimised AX-context
// detectors. Still deferred with reasons:
//   copy_to_search   — focus role is recorded, but search-paste inference remains
//                      outside this pilot's agreed scope
//   entity_overlap   — NER output is content-adjacent; needs the content-tier
//                      consent flow (M5) before names may leave the sensor layer

// MARK: - Intent classes & features

enum IntentClass: String, Codable, CaseIterable {
    case translation      // Translation / Transformation
    case comprehension    // Comprehension
    case discovery        // Discovery / Cross-Reference
}

enum FeatureID: String, Codable, CaseIterable {
    // translation
    case foreignLanguageClip      = "foreign_language_clip"
    case copyThenTranslatorSwitch = "copy_then_translator_switch"
    case copyTargetLanguageMismatch = "copy_target_language_mismatch"
    case formatMismatch           = "format_mismatch"
    // comprehension
    case reReading                = "re_reading"
    case visibleRangeRevisit      = "visible_range_revisit"
    case denseDwell               = "dense_dwell"
    case repeatSelection          = "repeat_selection"
    // discovery
    case collectMode              = "collect_mode"
    case topicCoherence           = "topic_coherence"

    var intentClass: IntentClass {
        switch self {
        case .foreignLanguageClip, .copyThenTranslatorSwitch,
             .copyTargetLanguageMismatch, .formatMismatch:
            return .translation
        case .reReading, .visibleRangeRevisit, .denseDwell, .repeatSelection:
            return .comprehension
        case .collectMode, .topicCoherence:
            return .discovery
        }
    }
}

/// One piece of typed evidence. Strength ∈ [0,1]; the scorer multiplies it with the
/// feature's weight and time decay.
struct Evidence {
    let feature: FeatureID
    let strength: Double
    let t: TimeInterval
}

// MARK: - Extractor

final class FeatureExtractor {

    /// Wired by IntentEngine to IntentScorer.add(_:).
    var emit: ((Evidence) -> Void)?
    /// Wired to the scorer for evidence whose truth depends on a still-current
    /// clipboard/target join rather than only on historical decay.
    var invalidate: ((FeatureID) -> Void)?

    // Detector state (all trimmed against event time)
    private struct Copy {
        let t: TimeInterval
        let hash: String
        let source: String?
        let isText: Bool
        let isForeignLanguage: Bool
        let shape: String
        let charCount: Int
        let language: String?
        let langConfidence: Double?
        let embedding: [Double]?
        /// Best-effort in-memory source identity captured while the copy's owner was
        /// still focused. This never crosses the signal bus or trace boundary.
        let sourceDocID: String?
        /// Content-free document/window segment at copy observation. This makes a
        /// same-process destination transition replayable even when either document
        /// does not expose a stable AXDocument identity.
        let sourceDocumentRevision: UInt64?
    }

    /// In-memory bridge for the M3 resolver — NEVER on the bus, never persisted:
    /// metadata of the newest participant-relative foreign-language copy OR the exact
    /// copy paired with a confidently different editable AX target language. At accept
    /// time the resolver re-reads NSPasteboard and matches `hash` to confirm the
    /// evidence object is still what's on the clipboard — raw text stays out of the
    /// pipeline until the moment the user says yes.
    struct ClipCandidate {
        let t: TimeInterval
        let hash: String
        let language: String?
        let langConfidence: Double?
        let source: String?
        let shape: String
        let charCount: Int
        /// Confident language of the editable AX destination. nil means the
        /// candidate came from participant-relative foreign-language evidence.
        let targetLanguage: String?
    }
    private(set) var translationCandidate: ClipCandidate?

    /// Newest text copy of ANY language — the object the comprehension and discovery
    /// suggestions act on. `translationCandidate` is deliberately kept separate: it
    /// tracks only copies backed by foreign-language or target-language-mismatch
    /// evidence, never ordinary text merely because it was copied.
    private(set) var latestTextCandidate: ClipCandidate?

    /// Fresh resolver accessors deliberately take event time. The extractor may sit
    /// idle for minutes after its last bus event; relying on `handle` to trim would let
    /// stale clipboard metadata live forever merely because nothing else happened.
    func translationCandidate(at t: TimeInterval) -> ClipCandidate? {
        trim(before: t)
        guard let candidate = translationCandidate, candidate.t <= t else { return nil }
        if candidate.targetLanguage != nil {
            guard let observedAt = targetCandidateObservedAt,
                  observedAt <= t,
                  t - observedAt <= Self.targetCandidateLifetime else {
                restoreParticipantRelativeCandidate(
                    copies.last(where: { $0.hash == candidate.hash && $0.t == candidate.t }))
                return translationCandidate
            }
        }
        return candidate
    }

    func latestTextCandidate(at t: TimeInterval) -> ClipCandidate? {
        trim(before: t)
        guard let candidate = latestTextCandidate, candidate.t <= t else { return nil }
        return candidate
    }

    /// Distinct things copied inside the collect window. Discovery only makes sense
    /// once the participant has gathered more than one fresh source.
    func distinctRecentCopies(at t: TimeInterval) -> Int {
        trim(before: t)
        return copies.filter { $0.t <= t }.count
    }

    private var copies: [Copy] = []                                  // 90 s window
    private var bursts: [(t: TimeInterval, app: String?, net: Double, flips: Int)] = []  // 60 s
    private struct DocumentKey: Hashable {
        let app: String
        let docID: String
    }
    private var selections: [(t: TimeInterval, key: DocumentKey, hash: String)] = []  // 60 s
    private struct VisibleRangeObservation {
        let t: TimeInterval
        let key: DocumentKey
        let start: Int
        let end: Int
    }
    private struct LanguageMismatch: Hashable {
        let copyT: TimeInterval
        let hash: String
    }
    private struct EmittedLanguageMismatch {
        let targetLanguage: String
        let strength: Double
    }
    private struct ContextObservation {
        let t: TimeInterval
        let payload: AccessibilityContextPayload
    }
    private var visibleRanges: [VisibleRangeObservation] = []          // 300 s window
    private var emittedLanguageMismatches: [LanguageMismatch: EmittedLanguageMismatch] = [:]
    private var latestContext: ContextObservation?
    private var currentFocusedApp: String?
    private var targetCandidateObservedAt: TimeInterval?
    private var targetCandidateDocID: String?
    private var targetCandidateApp: String?
    private var rangeCoverageByApp: [String: TimeInterval] = [:]
    private var documentRevision: UInt64 = 0

    private static let supportedTranslationTargets: Set<String> = ["en", "de", "fr", "es"]
    private static let reversePairingWindow: TimeInterval = 3
    private static let targetCandidateLifetime: TimeInterval = 15

    func handle(_ event: SignalEvent) {
        trim(before: event.t)
        switch event.kind {
        case .clipboard:   if let p = event.clipboard { onClipboard(p, t: event.t) }
        case .contextBoundary:
            if let p = event.contextBoundary { onContextBoundary(p) }
        case .appFocus:    if let p = event.appFocus { onAppFocus(p, t: event.t) }
        case .scrollBurst: if let p = event.scroll { onScrollBurst(p, t: event.t) }
        case .dwell:       if let p = event.dwell { onDwell(p, t: event.t) }
        case .selection:   if let p = event.selection { onSelection(p, t: event.t) }
        case .accessibilityContext:
            if let p = event.accessibilityContext { onAccessibilityContext(p, t: event.t) }
        // Segmentation metadata only — an idle span is not evidence of any intent.
        // It exists so the ANALYSIS can separate work from absence (and reading from
        // away-from-desk); feeding it to detectors would invent signal from silence.
        case .activity:    break
        }
    }

    func reset() {
        copies = []; bursts = []; selections = []; visibleRanges = []
        emittedLanguageMismatches = [:]
        translationCandidate = nil
        latestTextCandidate = nil
        latestContext = nil
        currentFocusedApp = nil
        targetCandidateObservedAt = nil
        targetCandidateDocID = nil
        targetCandidateApp = nil
        rangeCoverageByApp = [:]
        documentRevision = 0
    }

    /// A pause/stop must not leave an actionable raw-object alias behind. Detector
    /// history may remain for longitudinal scoring; only resolver-facing candidates
    /// are invalidated so the next action requires a newly observed copy.
    func clearResolverCandidates() {
        invalidateTargetMismatchEvidence(copyMatching: translationCandidate)
        translationCandidate = nil
        latestTextCandidate = nil
        latestContext = nil
        targetCandidateObservedAt = nil
        targetCandidateDocID = nil
        targetCandidateApp = nil
    }

    /// Pasteboard lifecycle boundary. Trace v5 records it even when the replacement is
    /// sensitive or unsupported; those cases correctly have no following content
    /// payload. Historical detector/vault observations remain, while aliases and
    /// evidence tied to what is *currently* on NSPasteboard are withdrawn.
    func pasteboardDidAdvance() {
        invalidateTargetMismatchEvidence(copyMatching: translationCandidate)
        translationCandidate = nil
        latestTextCandidate = nil
        targetCandidateObservedAt = nil
        targetCandidateDocID = nil
        targetCandidateApp = nil
    }

    private func onContextBoundary(_ payload: ContextBoundaryPayload) {
        switch payload.scope {
        case "pasteboard":
            pasteboardDidAdvance()
        case "accessibility_target":
            documentRevision &+= 1
            latestContext = nil
            // A conclusive window/document transition ends the old target join even
            // if the replacement target exposes no docID or readable language.
            if translationCandidate?.targetLanguage != nil,
               payload.app == nil || payload.app == targetCandidateApp {
                restoreParticipantRelativeCandidate(copyMatching: translationCandidate)
            }
        default:
            break
        }
    }

    private func trim(before t: TimeInterval) {
        copies.removeAll { $0.t < t - 90 }
        bursts.removeAll { $0.t < t - 60 }
        selections.removeAll { $0.t < t - 60 }
        visibleRanges.removeAll { $0.t < t - 300 }
        emittedLanguageMismatches = emittedLanguageMismatches.filter {
            $0.key.copyT >= t - 90
        }
        // `latestContext` is the last identity in the current focus segment and is
        // cleared by onAppFocus. It intentionally has no time TTL: unchanged 14 s AX
        // fallbacks are deduplicated, while a Word source may remain open for hours.
        // Reverse target-before-copy pairing still has its separate strict 3 s guard.
        rangeCoverageByApp = rangeCoverageByApp.filter { $0.value >= t - 30 }

        // Resolver caches are aliases into the 90-second copy window, not a second
        // unbounded history. Clear them as soon as their exact observation expires or
        // has been replaced by a newer copy of the same hash.
        if let candidate = translationCandidate,
           !copies.contains(where: { $0.hash == candidate.hash && $0.t == candidate.t }) {
            invalidateTargetMismatchEvidence(copyMatching: candidate)
            translationCandidate = nil
            targetCandidateObservedAt = nil
            targetCandidateDocID = nil
            targetCandidateApp = nil
        }
        if let candidate = latestTextCandidate,
           !copies.contains(where: { $0.hash == candidate.hash && $0.t == candidate.t && $0.isText }) {
            latestTextCandidate = nil
        }
    }

    // MARK: Clipboard → foreign_language_clip · format_mismatch(arm) · collect_mode · topic_coherence

    private func onClipboard(_ p: ClipboardPayload, t: TimeInterval) {
        // Every published clipboard class replaces the current pasteboard object.
        // Do this before filtering so URL/image/file rows cannot leave a text-bound
        // suggestion alive. Live v5 already emitted the explicit boundary first; this
        // idempotent call preserves identical semantics for legacy v4 clipboard rows.
        pasteboardDidAdvance()
        guard p.contentClass == "text" || p.contentClass == "url" else { return }

        let sourceDocID: String?
        if let context = latestContext,
           context.payload.app == p.sourceApp,
           currentFocusedApp == p.sourceApp,
           context.t <= t {
            sourceDocID = context.payload.docID
        } else {
            sourceDocID = nil
        }
        let sourceDocumentRevision = currentFocusedApp == p.sourceApp
            ? documentRevision : nil

        // Identical re-copy: REFRESH recency (remove + re-append keeps the array
        // time-ordered, so `last(where:)` stays correct) — a translator switch
        // right after re-copying must see a fresh copy. But never inflate the
        // distinct-copy count: collect_mode stays honest about "3 different things".
        let entry = Copy(t: t, hash: p.hashPrefix, source: p.sourceApp,
                         isText: p.contentClass == "text",
                         isForeignLanguage: p.isForeignLanguage, shape: p.shape,
                         charCount: p.charCount,
                         language: p.language, langConfidence: p.langConfidence,
                         embedding: p.embedding, sourceDocID: sourceDocID,
                         sourceDocumentRevision: sourceDocumentRevision)
        if let i = copies.firstIndex(where: { $0.hash == p.hashPrefix }) {
            copies.remove(at: i)
        }
        copies.append(entry)

        if p.contentClass == "text" {
            // The pasteboard now owns a new object. Never leave an actionable alias
            // pointing at an older copy merely because its 90-second metadata window
            // has not expired yet.
            latestTextCandidate = ClipCandidate(
                t: t, hash: p.hashPrefix, language: p.language,
                langConfidence: p.langConfidence, source: p.sourceApp, shape: p.shape,
                charCount: p.charCount, targetLanguage: nil)
        }

        if p.isForeignLanguage {
            // Strength: language confidence × snippet-length band (40–2000 chars is
            // the "worth translating" sweet spot — ARCHITECTURE §5 worked example).
            let band: Double = (40...2000).contains(p.charCount) ? 1.0 : 0.5
            emit?(Evidence(feature: .foreignLanguageClip,
                           strength: (p.langConfidence ?? 0.8) * band, t: t))
            translationCandidate = ClipCandidate(
                t: t, hash: p.hashPrefix, language: p.language,
                langConfidence: p.langConfidence, source: p.sourceApp, shape: p.shape,
                charCount: p.charCount, targetLanguage: nil)
        }

        // Clipboard polling can land just after the target app's freshly published
        // AX context. Pair in that reverse delivery order only while the context is
        // very recent, is still the focused app, and differs from the copy source.
        if p.contentClass == "text",
           let context = latestContext,
           (0...Self.reversePairingWindow).contains(t - context.t),
           currentFocusedApp == context.payload.app,
           let sourceApp = p.sourceApp,
           let targetApp = context.payload.app,
           sourceApp != targetApp {
            detectCopyTargetLanguageMismatch(context.payload, t: t,
                                             targetWasObservedBeforeCopy: true)
        }

        detectCollectMode(t: t)
    }

    private func detectCollectMode(t: TimeInterval) {
        let recent = copies.filter { $0.t > t - 90 }
        guard recent.count >= 3 else { return }

        // ≥3 distinct copies in 90 s ⇒ the user is collecting. Bundle IDs are not
        // source identities: three browser tabs are three sources but share one bundle.
        // The source app remains in the raw event for an offline sensitivity analysis.
        emit?(Evidence(feature: .collectMode,
                       strength: min(1.0, 0.5 + 0.25 * Double(recent.count - 3)), t: t))

        // Are the collected snippets ONE research thread? Mean pairwise cosine of
        // their embeddings, mapped so 0.35 → 0 and 0.75+ → 1 (ARCHITECTURE §8).
        // Only COMPARABLE pairs count: cross-language pairs (different NLEmbedding
        // dimensions) return nil and are skipped — never averaged in as a spurious
        // 0, which would falsely read a bilingual research session as incoherent.
        let vectors = recent.compactMap { copy -> (language: String, vector: [Double])? in
            guard let vector = copy.embedding, let language = copy.language else { return nil }
            return (String(language.prefix(2)).lowercased(), vector)
        }.suffix(4)
        guard vectors.count >= 2 else { return }
        var sims: [Double] = []
        for i in vectors.indices {
            for j in vectors.indices where j > i {
                // Apple's sentence embeddings are language-specific coordinate spaces,
                // even when their dimensions happen to match. Compare only like with
                // like until a multilingual aligned backbone is actually shipped.
                guard vectors[i].language == vectors[j].language else { continue }
                if let c = IntentText.cosine(vectors[i].vector, vectors[j].vector) {
                    sims.append(c)
                }
            }
        }
        guard !sims.isEmpty else { return }   // no comparable pairs (e.g. all cross-language)
        let mean = sims.reduce(0, +) / Double(sims.count)
        let strength = min(1.0, max(0.0, (mean - 0.35) / 0.4))
        if strength > 0 {
            emit?(Evidence(feature: .topicCoherence, strength: strength, t: t))
        }
    }

    // MARK: App focus → copy_then_translator_switch · format_mismatch(fire)

    private func onAppFocus(_ p: AppFocusPayload, t: TimeInterval) {
        if p.transition == "segment_end" {
            currentFocusedApp = nil
            latestContext = nil
            if translationCandidate?.targetLanguage != nil {
                restoreParticipantRelativeCandidate(copyMatching: translationCandidate)
            }
        } else {
            currentFocusedApp = p.bundleID
            if latestContext?.payload.app != p.bundleID { latestContext = nil }
            if let targetApp = targetCandidateApp, targetApp != p.bundleID,
               translationCandidate?.targetLanguage != nil {
                restoreParticipantRelativeCandidate(copyMatching: translationCandidate)
            }
        }

        // Segment bookkeeping completes app-time denominators but is not a user
        // switch and therefore cannot contribute intent evidence.
        guard p.transition == nil || p.transition == "activated" else { return }
        guard let lastTextCopy = copies.last(where: { $0.isText }) else { return }
        let sinceCopy = t - lastTextCopy.t

        // copy → translator app within 10 s: the strongest translation tell.
        if p.category == "translator", sinceCopy <= 10 {
            emit?(Evidence(feature: .copyThenTranslatorSwitch, strength: 1.0, t: t))
        }

        // code/table copied, then straight into a prose-shaped app — ONLY those
        // shapes constitute a transformation tell; arbitrary text → Notes is just
        // normal work and must not fire (weak evidence by design, weight 0.8).
        if sinceCopy <= 10,
           ["code", "table"].contains(lastTextCopy.shape),
           ["mail", "notes", "messaging"].contains(p.category) {
            emit?(Evidence(feature: .formatMismatch, strength: 0.8, t: t))
        }
    }

    // MARK: Selection → copy_then_translator_switch (web) · repeat_selection

    private func onSelection(_ p: SelectionPayload, t: TimeInterval) {
        // Translator context in a browser tab (deepl.com …) — AppFocusSensor can't
        // see tabs; the AX window title (hashed away at capture) can.
        if p.isTranslatorContext,
           let lastTextCopy = copies.last(where: { $0.isText }),
           t - lastTextCopy.t <= 10 {
            emit?(Evidence(feature: .copyThenTranslatorSwitch, strength: 0.9, t: t))
        }

        guard let app = p.app, let docID = p.docID,
              p.charCount > 0, !p.hashPrefix.isEmpty else { return }
        let key = DocumentKey(app: app, docID: docID)
        selections.append((t, key, p.hashPrefix))
        let sameSelection = selections.filter {
            $0.key == key && $0.hash == p.hashPrefix && $0.t > t - 60
        }.count
        if sameSelection >= 2 {
            emit?(Evidence(feature: .repeatSelection,
                           strength: min(1.0, Double(sameSelection - 1) / 3.0), t: t))
        }
    }

    // MARK: Accessibility context → target-language mismatch · visible-range revisit

    private func onAccessibilityContext(_ p: AccessibilityContextPayload,
                                        t: TimeInterval) {
        latestContext = ContextObservation(t: t, payload: p)
        if let app = p.app {
            currentFocusedApp = app
            if p.docID != nil, p.visibleStartBucket != nil, p.visibleEndBucket != nil {
                rangeCoverageByApp[app] = t
            } else {
                rangeCoverageByApp.removeValue(forKey: app)
            }
        }
        detectCopyTargetLanguageMismatch(p, t: t)
        detectVisibleRangeRevisit(p, t: t)
    }

    /// Target language is task evidence, not participant-relative foreignness. A user
    /// who comfortably reads both German and English can still intend to translate a
    /// German copy before inserting it into an English document. Observer duplicates
    /// are keyed to the exact clipboard observation so they cannot stack evidence.
    private func detectCopyTargetLanguageMismatch(_ p: AccessibilityContextPayload,
                                                  t: TimeInterval,
                                                  targetWasObservedBeforeCopy: Bool = false) {
        guard let copy = copies.last(where: { $0.isText && $0.t <= t }),
              let resolverCopy = latestTextCandidate,
              resolverCopy.hash == copy.hash, resolverCopy.t == copy.t else {
            if translationCandidate?.targetLanguage != nil {
                invalidateTargetMismatchEvidence(copyMatching: translationCandidate)
                translationCandidate = nil
                targetCandidateObservedAt = nil
                targetCandidateDocID = nil
                targetCandidateApp = nil
            }
            return
        }

        guard (0...Self.targetCandidateLifetime).contains(t - copy.t),
              copy.charCount >= 20,
              let sourceApp = copy.source else {
            restoreParticipantRelativeCandidate(copy)
            return
        }

        // A known app transition conclusively invalidates a previously bound target,
        // even when the new app does not expose a document identity. Missing app data
        // itself is merely unknown and must not erase good evidence.
        if translationCandidate?.targetLanguage != nil,
           let observedApp = p.app, let boundApp = targetCandidateApp,
           observedApp != boundApp {
            restoreParticipantRelativeCandidate(copy)
        }

        guard let targetApp = p.app, let targetDocID = p.docID else { return }

        if translationCandidate?.targetLanguage != nil,
           targetCandidateApp != targetApp || targetCandidateDocID != targetDocID {
            restoreParticipantRelativeCandidate(copy)
        }

        let sameKnownDocument = copy.sourceDocID != nil && copy.sourceDocID == targetDocID
        let changedKnownDocument = copy.sourceDocID != nil && copy.sourceDocID != targetDocID
        let changedDocumentRevision = copy.sourceDocumentRevision.map {
            $0 != documentRevision
        } ?? false
        let isDestinationTransition = sourceApp != targetApp
            || (!sameKnownDocument && (changedKnownDocument || changedDocumentRevision))
        guard (targetWasObservedBeforeCopy || t > copy.t), isDestinationTransition else {
            // This is a known return to the copy's source app/document, not an
            // unreadable target. It is conclusive counter-evidence.
            if translationCandidate?.targetLanguage != nil {
                restoreParticipantRelativeCandidate(copy)
            }
            return
        }

        // Unknown/temporarily unavailable AX values preserve an existing join for
        // the same target but can never create one. Only authoritative false or a
        // confident semantic contradiction retracts it.
        guard let editable = p.editable else { return }
        guard editable else {
            restoreParticipantRelativeCandidate(copy)
            return
        }
        guard p.readStrategy != "none", p.readStrategy != "range_metadata",
              p.sampleCharCount >= 20,
              let sourceConfidence = copy.langConfidence,
              let targetConfidence = p.langConfidence,
              let sourceLanguage = confidentLanguage(copy.language,
                                                      confidence: sourceConfidence),
              let targetLanguage = confidentLanguage(p.language,
                                                      confidence: targetConfidence) else {
            return
        }
        guard sourceLanguage != targetLanguage,
              Self.supportedTranslationTargets.contains(targetLanguage) else {
            restoreParticipantRelativeCandidate(copy)
            return
        }

        translationCandidate = ClipCandidate(
            t: copy.t, hash: copy.hash, language: copy.language,
            langConfidence: copy.langConfidence, source: copy.source, shape: copy.shape,
            charCount: copy.charCount, targetLanguage: targetLanguage)
        targetCandidateObservedAt = t
        targetCandidateDocID = targetDocID
        targetCandidateApp = p.app

        // One replaceable composite row per exact copy observation. Identical
        // observer callbacks do not refresh time, while a target-language change or
        // material confidence change replaces (never stacks) the object-bound row.
        let key = LanguageMismatch(copyT: copy.t, hash: copy.hash)
        let strength = min(sourceConfidence, targetConfidence)
        if let previous = emittedLanguageMismatches[key] {
            let materiallyChanged = previous.targetLanguage != targetLanguage
                || abs(previous.strength - strength) >= 0.1
            guard materiallyChanged else { return }
            invalidateTargetMismatchEvidence(for: copy)
        }
        emittedLanguageMismatches[key] = EmittedLanguageMismatch(
            targetLanguage: targetLanguage, strength: strength)
        emit?(Evidence(feature: .copyTargetLanguageMismatch,
                       strength: strength, t: t))
    }

    private func restoreParticipantRelativeCandidate(copyMatching candidate: ClipCandidate?) {
        guard let candidate else {
            restoreParticipantRelativeCandidate(nil)
            return
        }
        restoreParticipantRelativeCandidate(copies.last {
            $0.hash == candidate.hash && $0.t == candidate.t
        })
    }

    private func restoreParticipantRelativeCandidate(_ copy: Copy?) {
        invalidateTargetMismatchEvidence(for: copy)
        targetCandidateObservedAt = nil
        targetCandidateDocID = nil
        targetCandidateApp = nil
        guard let copy, copy.isForeignLanguage else {
            translationCandidate = nil
            return
        }
        translationCandidate = ClipCandidate(
            t: copy.t, hash: copy.hash, language: copy.language,
            langConfidence: copy.langConfidence, source: copy.source,
            shape: copy.shape, charCount: copy.charCount, targetLanguage: nil)
    }

    private func invalidateTargetMismatchEvidence(copyMatching candidate: ClipCandidate?) {
        let copy = candidate.flatMap { candidate in
            copies.last { $0.hash == candidate.hash && $0.t == candidate.t }
        }
        invalidateTargetMismatchEvidence(for: copy)
    }

    private func invalidateTargetMismatchEvidence(for copy: Copy?) {
        invalidate?(.copyTargetLanguageMismatch)
        if let copy {
            emittedLanguageMismatches.removeValue(
                forKey: LanguageMismatch(copyT: copy.t, hash: copy.hash))
        }
    }

    private func confidentLanguage(_ value: String?, confidence: Double?) -> String? {
        guard let value, let confidence, confidence > 0.6 else { return nil }
        let code = String(value.prefix(2)).lowercased()
        guard code.count == 2, code.allSatisfy(\.isLetter) else { return nil }
        return code
    }

    /// A revisit is a return to the exact same coarse visible interval after at least
    /// one different interval in the same document. Repeated observer callbacks for
    /// an unchanged range are ignored rather than miscounted as re-reading.
    private func detectVisibleRangeRevisit(_ p: AccessibilityContextPayload,
                                           t: TimeInterval) {
        guard let app = p.app, let docID = p.docID,
              let start = p.visibleStartBucket,
              let end = p.visibleEndBucket,
              start <= end else { return }
        let key = DocumentKey(app: app, docID: docID)
        let sameDocument = visibleRanges.filter { $0.key == key }
        if let last = sameDocument.last, last.start == start, last.end == end {
            return
        }
        let matched = sameDocument.last { $0.start == start && $0.end == end }
        let movementWasMaterial = sameDocument.last.map {
            abs($0.start - start) >= 2 || abs($0.end - end) >= 2
        } ?? false
        let triggerCanRepresentNavigation = ["scroll", "layout", "focus", "fallback"]
            .contains(p.trigger)
        let revisited = matched.map {
            t - $0.t >= 4
                && (sameDocument.last.map { t - $0.t >= 1 } ?? false)
                && movementWasMaterial
                && triggerCanRepresentNavigation
        } ?? false
        visibleRanges.append(VisibleRangeObservation(t: t, key: key,
                                                     start: start, end: end))
        if revisited {
            emit?(Evidence(feature: .visibleRangeRevisit, strength: 1.0, t: t))
        }
    }

    // MARK: Scroll → re_reading

    private func onScrollBurst(_ p: ScrollBurstPayload, t: TimeInterval) {
        // When the focused app is publishing real document-relative visible ranges,
        // let `visible_range_revisit` own re-reading evidence. The app-scoped scroll
        // heuristic is retained only as an explicit coverage fallback.
        if let app = p.app,
           let coveredAt = rangeCoverageByApp[app],
           t - coveredAt <= 30 {
            return
        }
        bursts.append((t, p.app, p.netDeltaY, p.directionChanges))

        // Within one burst: ≥3 direction flips is oscillation (re-reading a passage).
        if p.directionChanges >= 3 {
            emit?(Evidence(feature: .reReading,
                           strength: min(1.0, Double(p.directionChanges) / 6.0), t: t))
            return
        }

        // Across bursts (same app, 60 s): alternating net directions ≥3 times —
        // scroll down, back up, down again = the classic "read it again" pattern.
        let sameApp = bursts.filter { $0.app == p.app && abs($0.net) > 4 }
        guard sameApp.count >= 3 else { return }
        var alternations = 0
        for i in 1..<sameApp.count where sameApp[i].net.sign != sameApp[i - 1].net.sign {
            alternations += 1
        }
        if alternations >= 2 {
            emit?(Evidence(feature: .reReading,
                           strength: min(1.0, 0.4 + 0.2 * Double(alternations)), t: t))
        }
    }

    // MARK: Dwell → dense_dwell

    private func onDwell(_ p: DwellPayload, t: TimeInterval) {
        // Reading-shaped apps only; mouse-quiet in a terminal means something else.
        let category = p.app.map { AppFocusSensor.category(for: $0) } ?? "other"
        guard ["pdf", "browser", "editor", "notes"].contains(category) else { return }
        emit?(Evidence(feature: .denseDwell,
                       strength: min(1.0, p.seconds / 60.0), t: t))
    }
}
