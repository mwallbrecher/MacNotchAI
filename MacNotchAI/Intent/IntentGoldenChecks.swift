#if THESIS_STUDY_BUILD
import Foundation

// THESIS — golden smoke checks: an executable floor under the M2 pipeline.
//
// NOT the scientific evaluation (that is RQ1 on real traces, M5). This is a
// regression tripwire: when M3 adds policy, resolver, and UI, "the affordance is
// wrong" must be distinguishable from "the scoring regressed". Run from the debug
// menu (Intent Engine → Run Golden Checks); every check reports expected vs actual.
//
// Checks run on IN-MEMORY defaults (`IntentConfig()`), never the user's tweaked
// IntentConfig.json — otherwise every hand-tune would "fail" the suite.
enum IntentGoldenChecks {

    struct Check {
        let name: String
        let pass: Bool
        let detail: String
    }

    // MARK: Scenario plumbing

    /// A fresh, isolated extractor+scorer pair per scenario — no engine, no disk.
    private final class Pipeline {
        let extractor = FeatureExtractor()
        let scorer = IntentScorer(config: IntentConfig())
        init() {
            extractor.emit = { [scorer] in scorer.add($0) }
            extractor.invalidate = { [scorer] in scorer.remove($0) }
        }
        func feed(_ e: SignalEvent) { extractor.handle(e) }
        func p(_ c: IntentClass, at t: TimeInterval) -> Double {
            scorer.scores(at: t).first { $0.intentClass == c }?.probability ?? 0
        }
        func has(_ f: FeatureID) -> Bool {
            scorer.evidence.contains { $0.feature == f }
        }
    }

    private static func textClip(t: TimeInterval, foreign: Bool, conf: Double = 0.9,
                                 chars: Int = 200, shape: String = "prose",
                                 source: String, hash: String,
                                 language: String? = nil,
                                 embedding: [Double]? = nil) -> SignalEvent {
        SignalEvent(t: t, kind: .clipboard, clipboard: ClipboardPayload(
            contentClass: "text", charCount: chars, wordCount: chars / 6,
            language: language ?? (foreign ? "fr" : "en"), langConfidence: conf,
            isForeignLanguage: foreign, shape: shape, hasURL: false,
            hashPrefix: hash, sourceApp: source, fileExtensions: nil,
            embedding: embedding))
    }

    private static func focus(t: TimeInterval, bundle: String, category: String) -> SignalEvent {
        SignalEvent(t: t, kind: .appFocus, appFocus: AppFocusPayload(
            bundleID: bundle, appName: bundle, category: category,
            previousBundleID: "com.apple.Preview", secondsInPrevious: 30))
    }

    private static func accessibilityContext(
        t: TimeInterval, language: String? = nil, confidence: Double? = nil,
        editable: Bool? = false, docID: String? = "dddddddddddddddd",
        app: String = "com.microsoft.Word",
        start: Int? = nil, end: Int? = nil, trigger: String = "focus"
    ) -> SignalEvent {
        SignalEvent(t: t, kind: .accessibilityContext,
                    accessibilityContext: AccessibilityContextPayload(
                        app: app, docID: docID,
                        documentExtension: docID == nil ? nil : "docx",
                        focusedRole: "text_area",
                        editable: editable, language: language,
                        langConfidence: confidence,
                        sampleCharCount: language == nil ? 0 : 400,
                        readStrategy: start != nil ? "visible_range"
                            : (docID == nil ? "none" : "document_file"),
                        caretBucket: nil, visibleStartBucket: start,
                        visibleEndBucket: end, trigger: trigger))
    }

    nonisolated private static func pct(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }

    // MARK: The suite

    static func run() -> [Check] {
        var checks: [Check] = []
        let t0: TimeInterval = 1_000_000
        let balanced = IntentConfig().thresholds["balanced"] ?? 0.70

        // 1 · No evidence → every class sits at the prior.
        do {
            let pl = Pipeline()
            let ps = IntentClass.allCases.map { pl.p($0, at: t0) }
            let pass = ps.allSatisfy { abs($0 - 0.02) < 0.005 }
            checks.append(Check(name: "1 no evidence → prior (~2%)", pass: pass,
                                detail: "expected all ≈2%, got \(ps.map(pct).joined(separator: "/"))"))
        }

        // 2 · Foreign clip alone stays silent (< 0.45, well under balanced).
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a1"))
            let p = pl.p(.translation, at: t0 + 1)
            checks.append(Check(name: "2 foreign clip alone silent", pass: p < 0.45,
                                detail: "expected <45%, got \(pct(p))"))
        }

        // 3 · Translator switch alone (no copy) stays at the prior.
        do {
            let pl = Pipeline()
            pl.feed(focus(t: t0, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 1)
            checks.append(Check(name: "3 translator switch alone silent", pass: p < 0.05,
                                detail: "expected ≈prior, got \(pct(p))"))
        }

        // 4 · Foreign clip + translator switch crosses balanced.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a2"))
            pl.feed(focus(t: t0 + 3, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 3)
            checks.append(Check(name: "4 foreign clip + translator switch fires", pass: p >= balanced,
                                detail: "expected ≥\(pct(balanced)), got \(pct(p))"))
        }

        // 5 · Same evidence, read 5 min later → decayed back under threshold.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a3"))
            pl.feed(focus(t: t0 + 3, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 300)
            checks.append(Check(name: "5 evidence decays to silence", pass: p < 0.10,
                                detail: "expected <10% after 5 min, got \(pct(p))"))
        }

        // 6 · Ordinary english prose → Notes: format_mismatch must NOT fire.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: false, shape: "prose",
                             source: "com.apple.Safari", hash: "a4"))
            pl.feed(focus(t: t0 + 5, bundle: "com.apple.Notes", category: "notes"))
            let fired = pl.has(.formatMismatch)
            checks.append(Check(name: "6 prose → Notes: no format_mismatch", pass: !fired,
                                detail: fired ? "format_mismatch fired for prose" : "correctly silent"))
        }

        // 7 · code → Notes: format_mismatch DOES fire (positive control for 6).
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: false, shape: "code",
                             source: "com.apple.dt.Xcode", hash: "a5"))
            pl.feed(focus(t: t0 + 5, bundle: "com.apple.Notes", category: "notes"))
            let fired = pl.has(.formatMismatch)
            checks.append(Check(name: "7 code → Notes: format_mismatch fires", pass: fired,
                                detail: fired ? "fired as designed" : "did NOT fire"))
        }

        // 8 · Identical re-copy refreshes recency (translator switch 65 s after the
        //     ORIGINAL copy but 5 s after the RE-copy must fire) without inflating
        //     collect_mode. This check fails on the pre-fix extractor.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a6"))
            pl.feed(textClip(t: t0 + 60, foreign: true, source: "com.apple.Preview", hash: "a6"))
            pl.feed(focus(t: t0 + 65, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 65)
            let collect = pl.has(.collectMode)
            checks.append(Check(name: "8 re-copy refreshes recency, no collect stacking",
                                pass: p >= balanced && !collect,
                                detail: "translation \(pct(p)) (≥\(pct(balanced))?), collect_mode fired: \(collect)"))
        }

        // 9 · Pipeline reset returns to the pure prior.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a7"))
            pl.feed(focus(t: t0 + 3, bundle: "com.deepl.macos", category: "translator"))
            pl.extractor.reset(); pl.scorer.reset()
            let p = pl.p(.translation, at: t0 + 4)
            checks.append(Check(name: "9 reset → prior", pass: abs(p - 0.02) < 0.005,
                                detail: "expected ≈2%, got \(pct(p))"))
        }

        // 10 · A trace with a >1 s time regression is visibly rejected, not sorted.
        do {
            let dir = FileManager.default.temporaryDirectory
            let url = dir.appendingPathComponent("golden-nonmonotonic.jsonl")
            let encoder = JSONEncoder()
            let e1 = textClip(t: t0 + 100, foreign: false, source: "x", hash: "b1")
            let e2 = textClip(t: t0, foreign: false, source: "x", hash: "b2")   // 100 s backwards
            let lines = [e1, e2].compactMap { try? encoder.encode($0) }
                .compactMap { String(data: $0, encoding: .utf8) }
                .joined(separator: "\n")
            try? lines.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }

            var rejected = false
            do { _ = try TraceReplayer.load(url) } catch { rejected = true }
            checks.append(Check(name: "10 non-monotonic trace rejected", pass: rejected,
                                detail: rejected ? "rejected with error, as designed"
                                                 : "loaded without complaint"))
        }

        // 11 · Ticker-only class: even at 99%, comprehension must not pass the
        //      passive gate in M3 (it stays summon-only until evaluated on real data).
        do {
            let policy = AffordancePolicy()
            let v = policy.decide(intentClass: .comprehension, probability: 0.99,
                                  frontApp: nil, quietContext: false,
                                  at: t0, config: IntentConfig())
            checks.append(Check(name: "11 ticker-only class never passive", pass: !v.isShow,
                                detail: !v.isShow ? "comprehension blocked as designed"
                                                  : "comprehension passed the passive gate"))
        }

        // 12 · Dismiss cooldown: show → dismiss → blocked → expires → show again.
        do {
            var policy = AffordancePolicy()
            let cfg = IntentConfig()
            let first = policy.decide(intentClass: .translation, probability: 0.9,
                                      frontApp: nil, quietContext: false, at: t0, config: cfg).isShow
            policy.confirmShown(at: t0)
            policy.record(.dismissed, intentClass: .translation, at: t0 + 1, config: cfg)
            let blocked = !policy.decide(intentClass: .translation, probability: 0.9,
                                         frontApp: nil, quietContext: false,
                                         at: t0 + 2, config: cfg).isShow
            let after = policy.decide(intentClass: .translation, probability: 0.9,
                                      frontApp: nil, quietContext: false,
                                      at: t0 + 2 + cfg.dismissCooldownSeconds, config: cfg).isShow
            checks.append(Check(name: "12 dismiss cooldown blocks then expires",
                                pass: first && blocked && after,
                                detail: "show=\(first) blocked=\(blocked) after=\(after)"))
        }

        // 13 · Hourly rate limit: tier default exhausts, then the window slides.
        do {
            var policy = AffordancePolicy()
            let cfg = IntentConfig()
            for i in 0..<cfg.rateLimitPerHour { policy.confirmShown(at: t0 + Double(i)) }
            let blocked = !policy.decide(intentClass: .translation, probability: 0.9,
                                         frontApp: nil, quietContext: false,
                                         at: t0 + 10, config: cfg).isShow
            let later = policy.decide(intentClass: .translation, probability: 0.9,
                                      frontApp: nil, quietContext: false,
                                      at: t0 + 3700, config: cfg).isShow
            checks.append(Check(name: "13 hourly rate limit enforced, window slides",
                                pass: blocked && later,
                                detail: "blocked at \(cfg.rateLimitPerHour)/h=\(blocked), freed after window=\(later)"))
        }

        // 14 · "Foreign" follows the CONFIGURED repertoire, not the machine locale.
        //      This is the one the study depends on: Phase 1 runs on the researcher's
        //      Mac, so without the override every participant inherits the researcher's
        //      languages and foreign_language_clip is meaningless. Uses real German text
        //      through the real NaturalLanguage detector.
        do {
            let saved = IntentText.userLanguagesOverride
            defer { IntentText.userLanguagesOverride = saved }   // never leak into the live engine

            let german = "Die IT-Migration verzögert sich um drei bis vier Wochen wegen des CMS-Wechsels."

            IntentText.userLanguagesOverride = ["en"]            // participant reads English only
            let foreignForEnglishReader = IntentText.scalars(for: german, withEmbedding: false).isForeignLanguage

            IntentText.userLanguagesOverride = ["de", "en"]      // participant also reads German
            let foreignForGermanReader = IntentText.scalars(for: german, withEmbedding: false).isForeignLanguage

            let pass = foreignForEnglishReader && !foreignForGermanReader
            checks.append(Check(name: "14 foreign flag follows configured languages", pass: pass,
                                detail: "German text — reader[en]: foreign=\(foreignForEnglishReader) (want true), "
                                      + "reader[de,en]: foreign=\(foreignForGermanReader) (want false)"))
        }

        // 15 · Idle spans are SEGMENTATION, never evidence. The in-situ study records
        //      activity events so the analysis can separate work from absence, but an
        //      untouched machine must never move any intent hypothesis: silence is not
        //      a signal, and inventing one would corrupt the very base rate the prior
        //      encodes. Guards the deliberate `case .activity: break` in the extractor.
        do {
            let pipe = Pipeline()
            let t0: TimeInterval = 5_000
            pipe.feed(SignalEvent(t: t0, kind: .activity,
                                  activity: ActivityPayload(state: "idle", seconds: 900)))
            pipe.feed(SignalEvent(t: t0 + 900, kind: .activity,
                                  activity: ActivityPayload(state: "active", seconds: 900)))

            let evidenceCount = pipe.scorer.evidence.count
            let pTranslation = pipe.p(.translation, at: t0 + 901)
            let pComprehension = pipe.p(.comprehension, at: t0 + 901)
            let pDiscovery = pipe.p(.discovery, at: t0 + 901)
            let atPrior = [pTranslation, pComprehension, pDiscovery].allSatisfy { abs($0 - 0.02) < 0.005 }

            let pass = evidenceCount == 0 && atPrior
            checks.append(Check(name: "15 activity events create no evidence", pass: pass,
                                detail: "evidence=\(evidenceCount) (want 0), "
                                      + "p=[\(String(format: "%.3f", pTranslation)), "
                                      + "\(String(format: "%.3f", pComprehension)), "
                                      + "\(String(format: "%.3f", pDiscovery))] (want all ≈0.020)"))
        }

        // 16 · A live event derives ordering time and persisted clock metadata from
        //      one stamp. Equality is exact by construction — no timing tolerance.
        do {
            let event = SignalEvent.live(
                kind: .activity,
                activity: ActivityPayload(state: "active", seconds: 0))
            let sameUptime = event.uptime.map { event.t == $0 } ?? false
            let hasWall = event.wallTime.map { $0 > 0 } ?? false
            let hasSession = event.sessionID.map { !$0.isEmpty } ?? false
            let hasProcess = event.processID.map { $0 > 0 } ?? false
            let matchesProcess = event.processID == MonotonicClock.processID
            let matchesSession = event.sessionID == MonotonicClock.sessionID
            let pass = sameUptime && hasWall && hasSession && hasProcess
                    && matchesProcess && matchesSession
            checks.append(Check(name: "16 live signal carries one complete clock stamp",
                                pass: pass,
                                detail: "t==uptime=\(sameUptime), wall=\(hasWall), "
                                      + "session=\(hasSession && matchesSession), "
                                      + "process=\(hasProcess && matchesProcess)"))
        }

        // 17 · The content vault is exercised only through its RAM API. Preserve any
        //      live entries around the check so running diagnostics cannot destroy a
        //      participant's current candidate set. No URL/UserDefaults/file API is
        //      touched here.
        do {
            let vault = IntentContentVault.shared
            let now = MonotonicClock.now
            let savedSnapshot = vault.snapshot(at: now)
            let savedTexts = vault.texts(matching: savedSnapshot.references, at: now) ?? []
            let savedEntries = Array(zip(savedSnapshot.references, savedTexts))
            defer {
                vault.clear()
                for (reference, text) in savedEntries {
                    vault.store(text: text, hash: reference.hash, at: reference.capturedAt)
                }
            }

            vault.clear()
            vault.store(text: "source alpha", hash: "golden-alpha", at: now)
            vault.store(text: "source beta", hash: "golden-beta", at: now + 1)
            let snapshot = vault.snapshot(at: now + 1)
            let exactTexts = vault.texts(matching: snapshot.references, at: now + 1)
            let exact = snapshot.count == 2
                     && exactTexts == ["source alpha", "source beta"]

            vault.discard(Array(snapshot.references.prefix(1)))
            let discardWorked = vault.snapshot(at: now + 1).count == 1
                && vault.texts(matching: snapshot.references, at: now + 1) == nil

            vault.clear()
            let clearWorked = vault.snapshot(at: now + 1).count == 0
            vault.store(text: "expires", hash: "golden-expiry", at: now + 10)
            let expired = vault.snapshot(
                at: now + 10 + IntentContentVault.lifetime + 0.001).count == 0

            checks.append(Check(name: "17 RAM vault exact snapshot, discard, clear, TTL",
                                pass: exact && discardWorked && clearWorked && expired,
                                detail: "exact=\(exact), discard=\(discardWorked), "
                                      + "clear=\(clearWorked), expired=\(expired)"))
        }

        // 18 · A current explicit selection is the narrowest object. Give the context
        //      a non-nil clipboard candidate with an intentionally impossible hash as
        //      well as a document: the selection branch must win before any pasteboard
        //      validation is needed.
        do {
            let interactionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            let selection = DocumentReader.Snapshot(
                scope: .selection, pid: 101, bundleID: "golden.reader",
                appName: "Golden Reader", docID: "selection-doc",
                contentHash: "selection-hash", charCount: 120)
            let document = DocumentReader.Snapshot(
                scope: .document, pid: 101, bundleID: "golden.reader",
                appName: "Golden Reader", docID: "document-doc",
                contentHash: "document-hash", charCount: 5_000)
            let clipboard = FeatureExtractor.ClipCandidate(
                t: t0, hash: "not-a-valid-hash-prefix", language: "en",
                langConfidence: 1, source: "golden.clipboard", shape: "prose",
                charCount: 2_000, targetLanguage: nil)
            let context = TaskResolver.Context(
                now: t0, translationCandidate: nil, latestTextCandidate: clipboard,
                recentCopies: 1,
                vault: IntentContentVault.Snapshot(references: []),
                selection: selection, document: document)
            let suggestion = TaskResolver.resolve(
                intentClass: .comprehension, probability: 0.81,
                context: context, interactionID: interactionID,
                channel: .summon, rank: 2)

            let choseSelection: Bool
            if let suggestion, case .accessibility(let chosen) = suggestion.target {
                choseSelection = chosen.scope.rawValue == DocumentReader.Scope.selection.rawValue
                    && chosen.contentHash == selection.contentHash
                    && suggestion.action.rawValue == AIAction.explainSimply.rawValue
            } else {
                choseSelection = false
            }
            checks.append(Check(name: "18 comprehension prioritises current selection",
                                pass: choseSelection,
                                detail: choseSelection
                                    ? "selection won over clipboard and document"
                                    : "resolver did not target the current selection"))
        }

        // 19 · Discovery with two exact vault references must remain a real synthesis
        //      action and carry the surface's identity/rank unchanged into its target.
        do {
            let interactionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            let references = [
                IntentContentVault.Reference(hash: "vault-one", capturedAt: t0),
                IntentContentVault.Reference(hash: "vault-two", capturedAt: t0 + 1),
            ]
            let fallbackDocument = DocumentReader.Snapshot(
                scope: .document, pid: 202, bundleID: "golden.discovery",
                appName: "Golden Discovery", docID: "fallback-doc",
                contentHash: "fallback-hash", charCount: 4_000)
            let context = TaskResolver.Context(
                now: t0 + 1, translationCandidate: nil, latestTextCandidate: nil,
                recentCopies: 2,
                vault: IntentContentVault.Snapshot(references: references),
                selection: nil, document: fallbackDocument)
            let suggestion = TaskResolver.resolve(
                intentClass: .discovery, probability: 0.76,
                context: context, interactionID: interactionID,
                channel: .summon, rank: 3)

            let linked: Bool
            if let suggestion, case .clipboardVault(let chosen) = suggestion.target {
                linked = suggestion.action.rawValue == AIAction.turnIntoBrief.rawValue
                    && suggestion.interactionID == interactionID
                    && suggestion.channel.rawValue == AffordanceChannel.summon.rawValue
                    && suggestion.rank == 3
                    && chosen == references
            } else {
                linked = false
            }
            checks.append(Check(name: "19 discovery links two-source synthesis to row",
                                pass: linked,
                                detail: linked
                                    ? "turnIntoBrief · summon · rank 3 · exact references"
                                    : "action, linkage, or vault references differed"))
        }

        // 20 · Repeating a different phrase in the same document is not evidence for
        //      re-reading. Only the exact content-free selection fingerprint may fire.
        do {
            let pipe = Pipeline()
            func selection(_ t: TimeInterval, _ hash: String) -> SignalEvent {
                SignalEvent(t: t, kind: .selection, selection: SelectionPayload(
                    app: "golden.reader", charCount: 40, wordCount: 7,
                    language: "en", langConfidence: 1, isForeignLanguage: false,
                    shape: "prose", hashPrefix: hash, docID: "dddddddddddddddd",
                    isTranslatorContext: false))
            }
            pipe.feed(selection(t0, "aaaaaaaaaaaaaaaa"))
            pipe.feed(selection(t0 + 5, "bbbbbbbbbbbbbbbb"))
            let differentSilent = !pipe.has(.repeatSelection)
            pipe.feed(selection(t0 + 10, "aaaaaaaaaaaaaaaa"))
            let identicalFired = pipe.has(.repeatSelection)
            checks.append(Check(name: "20 repeat selection requires same fingerprint",
                                pass: differentSilent && identicalFired,
                                detail: "different silent=\(differentSilent), exact repeat=\(identicalFired)"))
        }

        // 21 · A persisted pause attaches event-driven sensors without publishing a
        //      baseline. This guards the relaunch path's promise of an empty gap.
        do {
            let bus = SignalBus()
            let sensor = AppFocusSensor()
            sensor.startSuspended(bus: bus)
            let emitted = bus.buffer.count
            sensor.stop()
            checks.append(Check(name: "21 suspended start emits no app baseline",
                                pass: emitted == 0,
                                detail: "events before resume=\(emitted) (want 0)"))
        }

        // 22–25 · Crash-tail repair, FIFO delivery and exporter schema validation run only against
        //         isolated in-memory/temporary fixtures, never participant data.
        do {
            let pass = TraceRecorder.tailRecoveryCheckForTesting()
            checks.append(Check(name: "22 recorder repairs only final interrupted tail",
                                pass: pass,
                                detail: pass ? "valid tail completed; partial tail discarded"
                                             : "isolated tail-recovery fixture failed"))
        }
        do {
            let pass = StudyExporter.schemaValidationCheckForTesting()
            checks.append(Check(name: "23 exporter enforces typed trace v5 + affordance v4",
                                pass: pass,
                                detail: pass ? "v5 AX + legacy v4 accepted; AX forbidden in v4; raw fields stripped"
                                             : "schema validator fixture failed"))
        }
        do {
            let pass = SignalBus.reentrantDeliveryCheckForTesting()
            checks.append(Check(name: "24 nested signal publication remains FIFO",
                                pass: pass,
                                detail: pass ? "both subscribers observed t1 before nested t2"
                                             : "re-entrant delivery reordered the stream"))
        }
        do {
            let pass = AffordanceController.tailRecoveryCheckForTesting()
            checks.append(Check(name: "25 affordance tail recovery is durably journaled",
                                pass: pass,
                                detail: pass ? "valid tail completed; partial tail audited and discarded"
                                             : "affordance recovery transaction fixture failed"))
        }

        // 26 · Browser tabs share a bundle ID but are still distinct collected sources.
        //      Conversely, equal-dimensional vectors from different language-specific
        //      Apple models must never be treated as one shared embedding space.
        do {
            let sameApp = Pipeline()
            for (offset, hash) in ["one", "two", "three"].enumerated() {
                sameApp.feed(textClip(t: t0 + Double(offset), foreign: false,
                                      source: "com.apple.Safari", hash: hash))
            }
            let sameAppCollects = sameApp.has(.collectMode)

            let mixed = Pipeline()
            mixed.feed(textClip(t: t0, foreign: false, source: "browser", hash: "en",
                                embedding: [1, 0, 0]))
            mixed.feed(textClip(t: t0 + 1, foreign: true, source: "browser", hash: "fr",
                                embedding: [1, 0, 0]))
            mixed.feed(textClip(t: t0 + 2, foreign: false, source: "browser", hash: "plain"))
            let mixedLanguageSkipped = !mixed.has(.topicCoherence)
            checks.append(Check(name: "26 discovery counts tabs, compares embeddings by language",
                                pass: sameAppCollects && mixedLanguageSkipped,
                                detail: "same-app collect=\(sameAppCollects), "
                                      + "cross-language skipped=\(mixedLanguageSkipped)"))
        }

        // 27 · Study setup must erase all pilot/user tuning except the explicitly
        //      declared participant language repertoire.
        do {
            var contaminated = IntentConfig()
            // "lazy" is the deviation marker: the frozen study posture is itself
            // aggressive, so tuning the tier DOWN is what a contaminated install
            // would look like.
            contaminated.tier = "lazy"
            contaminated.priorOffsets[IntentClass.translation.rawValue] = 1.2
            contaminated.weights[FeatureID.collectMode.rawValue] = -2
            contaminated.mutes = ["translation|example.app"]
            contaminated.userLanguages = ["DE-de", "en", "de"]
            let frozen = IntentConfig.studyConfiguration(
                userLanguages: contaminated.userLanguages)
            let pass = frozen.isFrozenStudyConfiguration
                // Study posture, inverted against the product default on purpose: a
                // missed offer produces no observation, a premature one still does.
                && frozen.tier == "aggressive"
                && Set(frozen.passiveClasses) == Set(IntentClass.allCases.map(\.rawValue))
                && IntentConfig().passiveClasses == [IntentClass.translation.rawValue]
                && frozen.priorOffsets.isEmpty
                && frozen.weights == IntentConfig.defaultWeights
                && frozen.mutes.isEmpty
                && frozen.userLanguages == ["de", "en"]
                && !contaminated.isFrozenStudyConfiguration
            checks.append(Check(name: "27 study configuration is frozen at cohort boundary",
                                pass: pass,
                                detail: pass ? "only normalised participant languages survive"
                                            : "pilot tuning leaked into frozen config"))
        }

        // 28 · The accepted-action handoff is a session-scoped one-shot, not a
        //      time-only payload. A mismatched revision must consume the stale latch,
        //      while controller lifecycle clears are scoped to the originating log.
        do {
            let result = IntentAutoRun.revisionBindingCheckForTesting()
            let pass = result.mismatchRejected
                && result.mismatchConsumed
                && result.wrongLogPreserved
                && result.exactLogCleared
                && result.unconditionalCleared
            checks.append(Check(name: "28 auto-run latch is revision and lifecycle bound",
                                pass: pass,
                                detail: "mismatch rejected=\(result.mismatchRejected), "
                                      + "mismatch consumed=\(result.mismatchConsumed), "
                                      + "wrong-log preserved=\(result.wrongLogPreserved), "
                                      + "exact-log clear=\(result.exactLogCleared), "
                                      + "unconditional clear=\(result.unconditionalCleared)"))
        }

        // 29 · Withdrawal must not relabel a completed cohort with whatever mutable
        //      scorer configuration happens to be loaded when export is requested.
        do {
            let pass = StudyExporter.deploymentSnapshotCheckForTesting()
            checks.append(Check(name: "29 export uses frozen deployment snapshot",
                                pass: pass,
                                detail: pass
                                    ? "post-withdraw mutations ignored; active drift rejected"
                                    : "deployment snapshot/config binding failed"))
        }

        // 30 · Participant erasure is a bounded recent suffix, never an arbitrary
        //      content query. Any interaction crossing the cutoff disappears as one
        //      lifecycle unit, and retrying the same durable request adds one receipt.
        do {
            let result = StudyTraceRedactor.redactionCheckForTesting()
            checks.append(Check(name: "30 recent-trace erasure is bounded and idempotent",
                                pass: result.pass,
                                detail: result.detail))
        }

        // 31 · A warm AX probe can finish before an older fade-out callback. That
        //      callback must not order out the newly presented summon surface, while
        //      the current hide intent must still be allowed to complete normally.
        do {
            let result = AffordanceController.summonPresentationCheckForTesting()
            let pass = result.staleHideRejected
                && result.currentHideAllowed
                && result.reopenPresented
            checks.append(Check(name: "31 summon re-open rejects stale window hide",
                                pass: pass,
                                detail: "stale rejected=\(result.staleHideRejected), "
                                      + "current allowed=\(result.currentHideAllowed), "
                                      + "re-open presented=\(result.reopenPresented)"))
        }

        // 32 · Accept may advance only through a returned revision that is both the
        //      live overlay revision and owner of the exact materialised source.
        do {
            let result = AffordanceController.sessionHandoffVerificationCheckForTesting()
            let pass = result.openerInvoked
                && result.openerRevisionForwarded
                && result.successAccepted
                && result.unchangedRejected
                && result.mismatchedReturnRejected
                && result.wrongFileRejected
                && result.preOpenReplacementRejected
            checks.append(Check(name: "32 accepted-action handoff verifies exact session",
                                pass: pass,
                                detail: "opener=\(result.openerInvoked), "
                                      + "revision forwarded=\(result.openerRevisionForwarded), "
                                      + "success=\(result.successAccepted), "
                                      + "unchanged rejected=\(result.unchangedRejected), "
                                      + "mismatch rejected=\(result.mismatchedReturnRejected), "
                                      + "wrong file rejected=\(result.wrongFileRejected), "
                                      + "pre-open replacement rejected="
                                      + "\(result.preOpenReplacementRejected)"))
        }

        // 33 · Target language is task context, not participant foreignness. A
        //      German+English reader copying German into an English editable DOCX
        //      still crosses balanced and selects the English catalogue action.
        do {
            let saved = IntentText.userLanguagesOverride
            defer { IntentText.userLanguagesOverride = saved }
            IntentText.userLanguagesOverride = ["de", "en"]
            let pipe = Pipeline()
            pipe.feed(textClip(t: t0, foreign: false, conf: 0.95,
                               source: "com.apple.Notes", hash: "golden-de-copy",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 2, language: "en",
                                           confidence: 0.96, editable: true))
            let probability = pipe.p(.translation, at: t0 + 2)
            let candidate = pipe.extractor.translationCandidate(at: t0 + 2)
            let action = TaskResolver.translateAction(
                preferredTargetLanguage: candidate?.targetLanguage,
                avoiding: candidate?.language)
            let invalidHashStillRejected = TaskResolver.resolveTranslation(
                candidate: candidate, probability: probability) == nil
            let pass = pipe.has(.copyTargetLanguageMismatch)
                && probability >= balanced
                && candidate?.targetLanguage == "en"
                && action.rawValue == AIAction.translateEnglish.rawValue
                && invalidHashStillRejected
            checks.append(Check(name: "33 bilingual copy/target mismatch selects target language",
                                pass: pass,
                                detail: "translation=\(pct(probability)), target="
                                      + "\(candidate?.targetLanguage ?? "nil"), action="
                                      + "\(action.rawValue), hash guard=\(invalidHashStillRejected)"))
        }

        // 34 · An editable destination in the copy's own language is ordinary paste,
        //      not translation intent, even when Accessibility supplies rich context.
        do {
            let pipe = Pipeline()
            pipe.feed(textClip(t: t0, foreign: false, conf: 0.95,
                               source: "com.apple.Notes", hash: "golden-de-same",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 2, language: "de",
                                           confidence: 0.96, editable: true))
            let probability = pipe.p(.translation, at: t0 + 2)
            let pass = !pipe.has(.copyTargetLanguageMismatch)
                && pipe.extractor.translationCandidate(at: t0 + 2) == nil
                && probability < balanced
            checks.append(Check(name: "34 same-language editable target stays silent",
                                pass: pass,
                                detail: "mismatch=\(pipe.has(.copyTargetLanguageMismatch)), "
                                      + "translation=\(pct(probability))"))
        }

        // 35 · Returning A → B → A is a coarse same-document revisit. A duplicate
        //      observer callback for unchanged A must not add another evidence row.
        do {
            let pipe = Pipeline()
            pipe.feed(accessibilityContext(t: t0, docID: "aaaaaaaaaaaaaaaa",
                                           start: 2, end: 5))
            pipe.feed(accessibilityContext(t: t0 + 5, docID: "aaaaaaaaaaaaaaaa",
                                           start: 8, end: 11))
            pipe.feed(accessibilityContext(t: t0 + 10, docID: "aaaaaaaaaaaaaaaa",
                                           start: 2, end: 5))
            pipe.feed(accessibilityContext(t: t0 + 20, docID: "aaaaaaaaaaaaaaaa",
                                           start: 2, end: 5))
            let count = pipe.scorer.evidence.filter {
                $0.feature == .visibleRangeRevisit
            }.count
            checks.append(Check(name: "35 visible-range revisit works and deduplicates",
                                pass: count == 1,
                                detail: "revisit evidence rows=\(count) (want 1)"))
        }

        // 36 · The sensor's pure privacy/normalisation helpers retain the exact
        //      4k sample, allowlist, language and 0...20 bucket contract.
        do {
            let result = SelectionSensor.accessibilityContextHelpersCheckForTesting()
            checks.append(Check(name: "36 AX context helper contract",
                                pass: result.passed, detail: result.detail))
        }

        // 37 · A copy outside the 15-second pairing window must not retain a target
        //      language merely because general clipboard metadata lives for 90 s.
        do {
            let pipe = Pipeline()
            pipe.feed(textClip(t: t0, foreign: false, conf: 0.95,
                               source: "com.apple.Notes", hash: "stale-de-copy",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 16, language: "en",
                                           confidence: 0.96, editable: true))
            let pass = !pipe.has(.copyTargetLanguageMismatch)
                && pipe.extractor.translationCandidate(at: t0 + 16) == nil
            checks.append(Check(name: "37 stale target-language pairing is rejected",
                                pass: pass,
                                detail: "mismatch=\(pipe.has(.copyTargetLanguageMismatch)), "
                                      + "candidate=\(pipe.extractor.translationCandidate(at: t0 + 16) != nil)"))
        }

        // 38 · Delivery order can legitimately be AX target first, delayed 0.5 s
        //      clipboard poll second. The tight reverse-pairing path must recover the
        //      cross-app Word scenario without pairing an arbitrary stale context.
        do {
            let pipe = Pipeline()
            pipe.feed(focus(t: t0, bundle: "com.microsoft.Word", category: "editor"))
            pipe.feed(accessibilityContext(t: t0 + 0.2, language: "en",
                                           confidence: 0.96, editable: true))
            pipe.feed(textClip(t: t0 + 0.5, foreign: false, conf: 0.95,
                               source: "com.apple.Notes", hash: "late-de-copy",
                               language: "de"))
            let candidate = pipe.extractor.translationCandidate(at: t0 + 0.5)
            let probability = pipe.p(.translation, at: t0 + 0.5)
            let pass = pipe.has(.copyTargetLanguageMismatch)
                && candidate?.targetLanguage == "en"
                && probability >= balanced
            checks.append(Check(name: "38 delayed clipboard pairs with focused AX target",
                                pass: pass,
                                detail: "translation=\(pct(probability)), target="
                                      + "\(candidate?.targetLanguage ?? "nil")"))
        }

        // 39 · A language just over the confidence floor may be useful data, but it
        //      must not be promoted to certainty and trigger a passive suggestion.
        do {
            let pipe = Pipeline()
            pipe.feed(textClip(t: t0, foreign: false, conf: 0.61,
                               source: "com.apple.Notes", hash: "weak-de-copy",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 2, language: "en",
                                           confidence: 0.61, editable: true))
            let probability = pipe.p(.translation, at: t0 + 2)
            let pass = pipe.has(.copyTargetLanguageMismatch) && probability < balanced
            checks.append(Check(name: "39 weak target-language confidence stays sub-threshold",
                                pass: pass, detail: "translation=\(pct(probability))"))
        }

        // 40 · The finite action catalogue cannot truthfully target Italian. Keep the
        //      raw AX/clipboard scalars for offline analysis, but do not emit decisive
        //      actionable mismatch evidence that would silently fall back to English.
        do {
            let pipe = Pipeline()
            pipe.feed(textClip(t: t0, foreign: false, conf: 0.95,
                               source: "com.apple.Notes", hash: "unsupported-target",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 2, language: "it",
                                           confidence: 0.96, editable: true))
            let pass = !pipe.has(.copyTargetLanguageMismatch)
                && pipe.extractor.translationCandidate(at: t0 + 2) == nil
            checks.append(Check(name: "40 unsupported target language is not actionable",
                                pass: pass,
                                detail: "mismatch=\(pipe.has(.copyTargetLanguageMismatch))"))
        }

        // 41 · Target-classifier changes update routing but cannot stack another
        //      weight-5 row. Unknown AX data preserves the valid join, conclusive
        //      same-language data retracts it, and a later valid target can re-arm it.
        do {
            let pipe = Pipeline()
            pipe.feed(textClip(t: t0, foreign: true, conf: 0.95,
                               source: "com.apple.Notes", hash: "foreign-target-flip",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 2, language: "en",
                                           confidence: 0.96, editable: true))
            pipe.feed(accessibilityContext(t: t0 + 4, language: "fr",
                                           confidence: 0.96, editable: true))
            let mismatchRows = pipe.scorer.evidence.filter {
                $0.feature == .copyTargetLanguageMismatch
            }.count
            let updatedTarget = pipe.extractor.translationCandidate(at: t0 + 4)?.targetLanguage
            pipe.feed(accessibilityContext(t: t0 + 5, language: "fr",
                                           confidence: 0.96, editable: nil))
            let unknownPreserved = pipe.scorer.evidence.contains {
                $0.feature == .copyTargetLanguageMismatch
            } && pipe.extractor.translationCandidate(at: t0 + 5)?.targetLanguage == "fr"
            pipe.feed(accessibilityContext(t: t0 + 6, language: "de",
                                           confidence: 0.96, editable: true))
            let restored = pipe.extractor.translationCandidate(at: t0 + 6)
            let remainingMismatchRows = pipe.scorer.evidence.filter {
                $0.feature == .copyTargetLanguageMismatch
            }.count
            pipe.feed(accessibilityContext(t: t0 + 8, language: "en",
                                           confidence: 0.96, editable: true))
            let rearmedRows = pipe.scorer.evidence.filter {
                $0.feature == .copyTargetLanguageMismatch
            }.count
            let rearmedTarget = pipe.extractor.translationCandidate(at: t0 + 8)?.targetLanguage
            let pass = mismatchRows == 1 && updatedTarget == "fr" && unknownPreserved
                && remainingMismatchRows == 0
                && restored != nil && restored?.targetLanguage == nil
                && rearmedRows == 1 && rearmedTarget == "en"
            checks.append(Check(name: "41 mismatch state retracts, preserves unknown, and re-arms",
                                pass: pass,
                                detail: "rows valid/retracted/rearmed=\(mismatchRows)/"
                                      + "\(remainingMismatchRows)/\(rearmedRows), unknown="
                                      + "\(unknownPreserved), "
                                      + "updated=\(updatedTarget ?? "nil"), "
                                      + "restoredForeign=\(restored != nil && restored?.targetLanguage == nil), "
                                      + "rearmed=\(rearmedTarget ?? "nil")"))
        }

        // 42 · Replay and export share one exact AX schema boundary: only v5 and
        //      only semantically valid strategies/buckets may enter the pipeline.
        do {
            let encoder = JSONEncoder()
            let event = accessibilityContext(t: t0, language: "en",
                                             confidence: 0.95, editable: true)
            let encoded = (try? encoder.encode(event)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            let directory = FileManager.default.temporaryDirectory
            let v4 = directory.appendingPathComponent("golden-ax-v4-\(UUID().uuidString).jsonl")
            let v5 = directory.appendingPathComponent("golden-ax-v5-\(UUID().uuidString).jsonl")
            let headerless = directory.appendingPathComponent(
                "golden-ax-headerless-\(UUID().uuidString).jsonl")
            let v6 = directory.appendingPathComponent("golden-ax-v6-\(UUID().uuidString).jsonl")
            let invalidBucket = directory.appendingPathComponent(
                "golden-ax-bucket-\(UUID().uuidString).jsonl")
            let invalidRangeMetadata = directory.appendingPathComponent(
                "golden-ax-range-metadata-\(UUID().uuidString).jsonl")
            defer {
                try? FileManager.default.removeItem(at: v4)
                try? FileManager.default.removeItem(at: v5)
                try? FileManager.default.removeItem(at: headerless)
                try? FileManager.default.removeItem(at: v6)
                try? FileManager.default.removeItem(at: invalidBucket)
                try? FileManager.default.removeItem(at: invalidRangeMetadata)
            }
            try? "{\"header\":{\"v\":4}}\n\(encoded)\n".write(
                to: v4, atomically: true, encoding: .utf8)
            try? "{\"header\":{\"v\":5}}\n\(encoded)\n".write(
                to: v5, atomically: true, encoding: .utf8)
            try? "\(encoded)\n".write(to: headerless, atomically: true, encoding: .utf8)
            try? "{\"header\":{\"v\":6}}\n\(encoded)\n".write(
                to: v6, atomically: true, encoding: .utf8)
            let bucketEvent = accessibilityContext(t: t0, language: "en",
                                                    confidence: 0.95, editable: true,
                                                    start: 99, end: 99)
            let bucketEncoded = (try? encoder.encode(bucketEvent)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            try? "{\"header\":{\"v\":5}}\n\(bucketEncoded)\n".write(
                to: invalidBucket, atomically: true, encoding: .utf8)
            let rangeMetadataEvent = SignalEvent(
                t: t0, kind: .accessibilityContext,
                accessibilityContext: AccessibilityContextPayload(
                    app: "com.microsoft.Word", docID: "dddddddddddddddd",
                    documentExtension: "docx", focusedRole: "text_area",
                    editable: true, language: "en", langConfidence: 0.95,
                    sampleCharCount: 400, readStrategy: "range_metadata",
                    caretBucket: nil, visibleStartBucket: 2, visibleEndBucket: 5,
                    trigger: "focus"))
            let rangeMetadataEncoded = (try? encoder.encode(rangeMetadataEvent)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            try? "{\"header\":{\"v\":5}}\n\(rangeMetadataEncoded)\n".write(
                to: invalidRangeMetadata, atomically: true, encoding: .utf8)
            var v4Rejected = false
            do { _ = try TraceReplayer.load(v4) } catch { v4Rejected = true }
            var headerlessRejected = false
            do { _ = try TraceReplayer.load(headerless) } catch { headerlessRejected = true }
            var v6Rejected = false
            do { _ = try TraceReplayer.load(v6) } catch { v6Rejected = true }
            var bucketRejected = false
            do { _ = try TraceReplayer.load(invalidBucket) } catch { bucketRejected = true }
            var rangeMetadataRejected = false
            do { _ = try TraceReplayer.load(invalidRangeMetadata) } catch {
                rangeMetadataRejected = true
            }
            let v5Events = (try? TraceReplayer.load(v5).events.count) ?? -1
            checks.append(Check(name: "42 replay enforces trace-v5 AX boundary",
                                pass: v4Rejected && headerlessRejected && v6Rejected
                                    && bucketRejected && rangeMetadataRejected && v5Events == 1,
                                detail: "v4/headerless/v6 rejected=\(v4Rejected)/"
                                      + "\(headerlessRejected)/\(v6Rejected), bucket/range="
                                      + "\(bucketRejected)/\(rangeMetadataRejected), "
                                      + "v5 events=\(v5Events)"))
        }

        // 43 · A decisive mismatch belongs to one exact clipboard object. Every
        //      published replacement class, plus the local privacy-gated boundary,
        //      retracts score and resolver aliases immediately.
        do {
            func primed() -> Pipeline {
                let pipe = Pipeline()
                pipe.feed(textClip(t: t0, foreign: false, conf: 0.95,
                                   source: "com.apple.Notes", hash: "object-a",
                                   language: "de"))
                pipe.feed(accessibilityContext(t: t0 + 2, language: "en",
                                               confidence: 0.96, editable: true))
                return pipe
            }
            func replacement(_ contentClass: String) -> SignalEvent {
                SignalEvent(t: t0 + 4, kind: .clipboard,
                            clipboard: ClipboardPayload(
                                contentClass: contentClass,
                                charCount: contentClass == "url" ? 20 : 0,
                                wordCount: contentClass == "url" ? 1 : 0,
                                language: nil, langConfidence: nil,
                                isForeignLanguage: false, shape: "",
                                hasURL: contentClass == "url",
                                hashPrefix: contentClass == "image" ? "" : "replacement-hash",
                                sourceApp: "com.microsoft.Word",
                                fileExtensions: contentClass == "files" ? ["pdf"] : nil))
            }
            func wasRetracted(_ pipe: Pipeline) -> Bool {
                !pipe.has(.copyTargetLanguageMismatch)
                    && pipe.extractor.translationCandidate(at: t0 + 4) == nil
                    && pipe.p(.translation, at: t0 + 4) < balanced
            }

            let textPipe = primed()
            textPipe.feed(textClip(t: t0 + 4, foreign: false, conf: 0.95,
                                   source: "com.microsoft.Word", hash: "object-b",
                                   language: "en"))
            let text = wasRetracted(textPipe)
                && textPipe.extractor.latestTextCandidate(at: t0 + 4)?.hash == "object-b"
            var classes: [String: Bool] = [:]
            for contentClass in ["url", "image", "files"] {
                let pipe = primed()
                pipe.feed(replacement(contentClass))
                classes[contentClass] = wasRetracted(pipe)
                    && pipe.extractor.latestTextCandidate(at: t0 + 4) == nil
            }
            let privatePipe = primed()
            privatePipe.feed(SignalEvent(
                t: t0 + 4, kind: .contextBoundary,
                contextBoundary: ContextBoundaryPayload(scope: "pasteboard", app: nil)))
            let privateBoundary = wasRetracted(privatePipe)
                && privatePipe.extractor.latestTextCandidate(at: t0 + 4) == nil
            let pass = text && classes.values.allSatisfy { $0 } && privateBoundary
            checks.append(Check(name: "43 clipboard replacement retracts target mismatch",
                                pass: pass,
                                detail: "text=\(text), url=\(classes["url"] == true), "
                                      + "image=\(classes["image"] == true), "
                                      + "files=\(classes["files"] == true), "
                                      + "private/unsupported=\(privateBoundary)"))
        }

        // 44 · Same-bundle copies bind to the document/window segment that existed
        //      when the clipboard event was ordered. A boundary after the copy is a
        //      destination transition; the same boundary before the copy is not.
        do {
            let pipe = Pipeline()
            pipe.feed(accessibilityContext(t: t0, language: "en", confidence: 0.96,
                                           editable: true, docID: "source-document-a"))
            pipe.feed(textClip(t: t0 + 60, foreign: false, conf: 0.95,
                               source: "com.microsoft.Word", hash: "same-doc-copy",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 60.5, language: "en", confidence: 0.96,
                                           editable: true, docID: "source-document-a"))
            let sameDocumentSilent = !pipe.has(.copyTargetLanguageMismatch)
            pipe.feed(SignalEvent(
                t: t0 + 60.75, kind: .contextBoundary,
                contextBoundary: ContextBoundaryPayload(
                    scope: "accessibility_target", app: "com.microsoft.Word")))
            pipe.feed(accessibilityContext(t: t0 + 61, language: "en", confidence: 0.96,
                                           editable: true, docID: "target-document-b"))
            let differentDocumentDetected = pipe.has(.copyTargetLanguageMismatch)
                && pipe.extractor.translationCandidate(at: t0 + 61)?.targetLanguage == "en"

            let copiedAfterBoundary = Pipeline()
            copiedAfterBoundary.feed(accessibilityContext(
                t: t0, language: "en", confidence: 0.96,
                editable: true, docID: "source-document-a"))
            copiedAfterBoundary.feed(SignalEvent(
                t: t0 + 1, kind: .contextBoundary,
                contextBoundary: ContextBoundaryPayload(
                    scope: "accessibility_target", app: "com.microsoft.Word")))
            copiedAfterBoundary.feed(textClip(
                t: t0 + 1.2, foreign: false, conf: 0.95,
                source: "com.microsoft.Word", hash: "copy-in-target-doc",
                language: "de"))
            copiedAfterBoundary.feed(accessibilityContext(
                t: t0 + 2, language: "en", confidence: 0.96,
                editable: true, docID: "target-document-b"))
            let postBoundaryCopySilent = !copiedAfterBoundary.has(.copyTargetLanguageMismatch)
            checks.append(Check(name: "44 mismatch requires a destination transition",
                                pass: sameDocumentSilent && differentDocumentDetected
                                    && postBoundaryCopySilent,
                                detail: "60 s source binding silent=\(sameDocumentSilent), "
                                      + "different doc detected=\(differentDocumentDetected), "
                                      + "copy after boundary silent=\(postBoundaryCopySilent)"))
        }

        // 45 · A common title such as "Untitled" may hash to the same docID in two
        //      apps. Document evidence is keyed by (app, docID), so cross-app rows
        //      cannot manufacture repeat-selection or A→B→A revisit evidence.
        do {
            let selectionPipe = Pipeline()
            func selection(_ t: TimeInterval, app: String) -> SignalEvent {
                SignalEvent(t: t, kind: .selection, selection: SelectionPayload(
                    app: app, charCount: 40, wordCount: 7,
                    language: "en", langConfidence: 1, isForeignLanguage: false,
                    shape: "prose", hashPrefix: "same-selection-hash",
                    docID: "same-untitled-id", isTranslatorContext: false))
            }
            selectionPipe.feed(selection(t0, app: "golden.app.one"))
            selectionPipe.feed(selection(t0 + 5, app: "golden.app.two"))
            let repeatSilent = !selectionPipe.has(.repeatSelection)

            let rangePipe = Pipeline()
            rangePipe.feed(accessibilityContext(t: t0, app: "golden.app.one",
                                                start: 2, end: 5))
            rangePipe.feed(accessibilityContext(t: t0 + 5, app: "golden.app.two",
                                                start: 8, end: 11))
            rangePipe.feed(accessibilityContext(t: t0 + 10, app: "golden.app.one",
                                                start: 2, end: 5))
            let revisitSilent = !rangePipe.has(.visibleRangeRevisit)
            checks.append(Check(name: "45 document evidence includes app identity",
                                pass: repeatSilent && revisitSilent,
                                detail: "cross-app repeat silent=\(repeatSilent), "
                                      + "cross-app revisit silent=\(revisitSilent)"))
        }

        // 46 · Material confidence changes replace the one object-bound row. A
        //      weak first target can become actionable, a weaker reclassification can
        //      lower it again, and identical observer duplicates never refresh time.
        do {
            let rising = Pipeline()
            rising.feed(textClip(t: t0, foreign: false, conf: 0.96,
                                 source: "com.apple.Notes", hash: "confidence-rises",
                                 language: "de"))
            rising.feed(accessibilityContext(t: t0 + 2, language: "en",
                                             confidence: 0.61, editable: true))
            let weakProbability = rising.p(.translation, at: t0 + 2)
            rising.feed(accessibilityContext(t: t0 + 4, language: "en",
                                             confidence: 0.96, editable: true))
            let strongProbability = rising.p(.translation, at: t0 + 4)
            let replacedAt = rising.scorer.evidence.first {
                $0.feature == .copyTargetLanguageMismatch
            }?.t
            rising.feed(accessibilityContext(t: t0 + 6, language: "en",
                                             confidence: 0.96, editable: true))
            let duplicateDidNotRefresh = rising.scorer.evidence.first {
                $0.feature == .copyTargetLanguageMismatch
            }?.t == replacedAt

            let falling = Pipeline()
            falling.feed(textClip(t: t0, foreign: false, conf: 0.96,
                                  source: "com.apple.Notes", hash: "confidence-falls",
                                  language: "de"))
            falling.feed(accessibilityContext(t: t0 + 2, language: "en",
                                              confidence: 0.96, editable: true))
            falling.feed(accessibilityContext(t: t0 + 4, language: "en",
                                              confidence: 0.61, editable: true))
            let loweredProbability = falling.p(.translation, at: t0 + 4)
            let oneRow = rising.scorer.evidence.filter {
                $0.feature == .copyTargetLanguageMismatch
            }.count == 1 && falling.scorer.evidence.filter {
                $0.feature == .copyTargetLanguageMismatch
            }.count == 1
            let pass = weakProbability < balanced && strongProbability >= balanced
                && loweredProbability < balanced && duplicateDidNotRefresh && oneRow
            checks.append(Check(name: "46 mismatch confidence replaces without stacking",
                                pass: pass,
                                detail: "weak/strong/lowered=\(pct(weakProbability))/"
                                      + "\(pct(strongProbability))/\(pct(loweredProbability)), "
                                      + "duplicate stable=\(duplicateDidNotRefresh), rows=\(oneRow)"))
        }

        // 47 · Content-free object boundaries are first-class v5 trace data. Replay
        //      must retract the same mismatch as live capture, and an AX boundary
        //      remains conclusive even if the replacement target has no docID/read.
        do {
            let pipe = Pipeline()
            pipe.feed(textClip(t: t0, foreign: false, conf: 0.95,
                               source: "com.apple.Notes", hash: "boundary-object",
                               language: "de"))
            pipe.feed(accessibilityContext(t: t0 + 2, language: "en",
                                           confidence: 0.96, editable: true))
            pipe.feed(SignalEvent(
                t: t0 + 3, kind: .contextBoundary,
                contextBoundary: ContextBoundaryPayload(
                    scope: "accessibility_target", app: "com.microsoft.Word")))
            pipe.feed(accessibilityContext(t: t0 + 4, language: nil,
                                           confidence: nil, editable: nil,
                                           docID: nil))
            let missingTargetRetracted = !pipe.has(.copyTargetLanguageMismatch)
                && pipe.extractor.translationCandidate(at: t0 + 4) == nil

            let boundary = SignalEvent(
                t: t0, kind: .contextBoundary,
                contextBoundary: ContextBoundaryPayload(scope: "pasteboard", app: nil))
            let invalidBoundary = SignalEvent(
                t: t0, kind: .contextBoundary,
                contextBoundary: ContextBoundaryPayload(scope: "unknown", app: nil))
            let encoder = JSONEncoder()
            let encoded = (try? encoder.encode(boundary)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            let invalidEncoded = (try? encoder.encode(invalidBoundary)).flatMap {
                String(data: $0, encoding: .utf8)
            } ?? ""
            let directory = FileManager.default.temporaryDirectory
            let v4 = directory.appendingPathComponent(
                "golden-boundary-v4-\(UUID().uuidString).jsonl")
            let v5 = directory.appendingPathComponent(
                "golden-boundary-v5-\(UUID().uuidString).jsonl")
            let invalid = directory.appendingPathComponent(
                "golden-boundary-invalid-\(UUID().uuidString).jsonl")
            defer {
                try? FileManager.default.removeItem(at: v4)
                try? FileManager.default.removeItem(at: v5)
                try? FileManager.default.removeItem(at: invalid)
            }
            try? "{\"header\":{\"v\":4}}\n\(encoded)\n".write(
                to: v4, atomically: true, encoding: .utf8)
            try? "{\"header\":{\"v\":5}}\n\(encoded)\n".write(
                to: v5, atomically: true, encoding: .utf8)
            try? "{\"header\":{\"v\":5}}\n\(invalidEncoded)\n".write(
                to: invalid, atomically: true, encoding: .utf8)
            var v4Rejected = false
            do { _ = try TraceReplayer.load(v4) } catch { v4Rejected = true }
            var invalidRejected = false
            do { _ = try TraceReplayer.load(invalid) } catch { invalidRejected = true }
            let v5Count = (try? TraceReplayer.load(v5).events.count) ?? -1
            let pass = missingTargetRetracted && v4Rejected && invalidRejected && v5Count == 1
            checks.append(Check(name: "47 context boundaries replay and retract exactly",
                                pass: pass,
                                detail: "missing target retracted=\(missingTargetRetracted), "
                                      + "v4/invalid rejected=\(v4Rejected)/\(invalidRejected), "
                                      + "v5 events=\(v5Count)"))
        }

        // 48 · The separate accept-time DocumentReader must enforce the same hard
        //      secure-field boundary as the background sensor. Missing/ambiguous role
        //      transport is fail-closed; an ordinary optional subrole may proceed.
        do {
            let result = DocumentReader.secureReadBoundaryCheckForTesting()
            checks.append(Check(name: "48 document reader secure gate fails closed",
                                pass: result.passed, detail: result.detail))
        }

        // 49 · Accept-time re-verification is scope-dependent. A selection claims exact
        //      words and must match byte for byte; an IDENTIFIED document claims "what
        //      you are working in", which survives editing between offer and accept.
        //      An unidentified document has nothing to anchor sameness on and stays
        //      strict, so a switch to another file in the same app cannot slip through.
        do {
            let selectionStrict = DocumentReader.requiresExactContent(
                scope: .selection, docID: "doc-1")
            let selectionStrictWithoutID = DocumentReader.requiresExactContent(
                scope: .selection, docID: nil)
            let documentRelaxed = !DocumentReader.requiresExactContent(
                scope: .document, docID: "doc-1")
            let unidentifiedStrict = DocumentReader.requiresExactContent(
                scope: .document, docID: nil)
            let pass = selectionStrict && selectionStrictWithoutID
                && documentRelaxed && unidentifiedStrict
            checks.append(Check(name: "49 accept re-verification is scope-dependent",
                                pass: pass,
                                detail: "selection_strict=\(selectionStrict), "
                                      + "selection_strict_no_id=\(selectionStrictWithoutID), "
                                      + "document_relaxed=\(documentRelaxed), "
                                      + "unidentified_strict=\(unidentifiedStrict)"))
        }

        // 50 · EVERY known frozen baseline must stay exportable, not just the newest.
        //      A deployment recorded under an earlier baseline has to validate after
        //      the study posture moves; when this check fails, a study already running
        //      in the field has just lost the ability to export its capture.
        do {
            let languages = ["de", "en"]
            let allValidate = IntentConfig.StudyBaseline.allCases.allSatisfy {
                IntentConfig.studyConfiguration(userLanguages: languages, baseline: $0)
                    .isFrozenStudyConfiguration
            }
            // Baselines must remain distinguishable, otherwise appending one is a no-op.
            let distinct = Set(IntentConfig.StudyBaseline.allCases.map {
                IntentConfig.studyConfiguration(userLanguages: languages, baseline: $0).tier
            }).count == IntentConfig.StudyBaseline.allCases.count
            var handTuned = IntentConfig.studyConfiguration(userLanguages: languages)
            handTuned.weights[FeatureID.collectMode.rawValue] = -2
            let rejectsTuning = !handTuned.isFrozenStudyConfiguration
            let pass = allValidate && distinct && rejectsTuning
            checks.append(Check(name: "50 every known study baseline stays exportable",
                                pass: pass,
                                detail: "baselines=\(IntentConfig.StudyBaseline.allCases.count), "
                                      + "all_validate=\(allValidate), distinct=\(distinct), "
                                      + "rejects_hand_tuning=\(rejectsTuning)"))
        }

        // 51 · Every silence the policy can report must survive export. One reason the
        //      exporter does not recognise invalidates the ENTIRE affordance log, and a
        //      day of capture with it. This drives the real producer through each
        //      branch instead of restating its strings — restating them is exactly how
        //      the two drifted apart.
        do {
            let config = IntentConfig.studyConfiguration(userLanguages: ["de", "en"])
            let t: TimeInterval = 1_000
            var reasons: [String] = []
            func capture(_ verdict: AffordancePolicy.Verdict) {
                if case .silent(let reason) = verdict { reasons.append(reason) }
            }
            func decide(_ policy: inout AffordancePolicy, probability: Double,
                        app: String, quiet: Bool, at time: TimeInterval,
                        config: IntentConfig) {
                capture(policy.decide(intentClass: .translation, probability: probability,
                                      frontApp: app, quietContext: quiet,
                                      at: time, config: config))
            }

            var tickerOnlyConfig = config
            tickerOnlyConfig.passiveClasses = []
            var policy = AffordancePolicy()
            decide(&policy, probability: 0.99, app: "a.app", quiet: false,
                   at: t, config: tickerOnlyConfig)                       // ticker-only
            decide(&policy, probability: 0.01, app: "a.app", quiet: false,
                   at: t, config: config)                                 // below θ(tier)
            decide(&policy, probability: 0.99, app: "a.app", quiet: true,
                   at: t, config: config)                                 // quiet context
            policy.mute(intentClass: .translation, app: "a.app")
            decide(&policy, probability: 0.99, app: "a.app", quiet: false,
                   at: t, config: config)                                 // muted

            var cooled = AffordancePolicy()
            cooled.record(.dismissed, intentClass: .translation, at: t, config: config)
            decide(&cooled, probability: 0.99, app: "b.app", quiet: false,
                   at: t + 1, config: config)                             // cooldown

            var limited = AffordancePolicy()
            for i in 0..<config.rateLimitPerHour { limited.confirmShown(at: t + Double(i)) }
            decide(&limited, probability: 0.99, app: "b.app", quiet: false,
                   at: t + 100, config: config)                           // rate limit (tier!)

            // The controller adds these two when a resolution comes back empty.
            let all = reasons + ["stale_or_replaced_candidate", "no_resolvable_object"]
            let unexportable = all.filter { !StudyExporter.validBlockedReason($0) }
            let pass = reasons.count == 6 && unexportable.isEmpty
            checks.append(Check(name: "51 every policy silence is exportable",
                                pass: pass,
                                detail: pass
                                    ? "\(all.count) reasons, all accepted"
                                    : "branches=\(reasons.count)/6, unexportable: "
                                        + unexportable.joined(separator: " | ")))
        }

        return checks
    }

    static func report() -> String {
        let checks = run()
        let failed = checks.filter { !$0.pass }
        let head = failed.isEmpty
            ? "ALL \(checks.count) CHECKS PASSED"
            : "⚠️ \(failed.count) OF \(checks.count) CHECKS FAILED"
        let lines = checks.map { "\($0.pass ? "✓" : "✗ FAILED") \($0.name)\n    \($0.detail)" }
        return head + "\n\n" + lines.joined(separator: "\n")
    }
}
#endif
