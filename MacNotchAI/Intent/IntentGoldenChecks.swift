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
        init() { extractor.emit = { [scorer] in scorer.add($0) } }
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
                                 embedding: [Double]? = nil) -> SignalEvent {
        SignalEvent(t: t, kind: .clipboard, clipboard: ClipboardPayload(
            contentClass: "text", charCount: chars, wordCount: chars / 6,
            language: foreign ? "fr" : "en", langConfidence: conf,
            isForeignLanguage: foreign, shape: shape, hasURL: false,
            hashPrefix: hash, sourceApp: source, fileExtensions: nil,
            embedding: embedding))
    }

    private static func focus(t: TimeInterval, bundle: String, category: String) -> SignalEvent {
        SignalEvent(t: t, kind: .appFocus, appFocus: AppFocusPayload(
            bundleID: bundle, appName: bundle, category: category,
            previousBundleID: "com.apple.Preview", secondsInPrevious: 30))
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
                charCount: 2_000)
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
            checks.append(Check(name: "23 exporter enforces typed v4/v4 schemas",
                                pass: pass,
                                detail: pass ? "valid trace/lifecycle accepted; bad link rejected; unknown field stripped"
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
            contaminated.tier = "aggressive"
            contaminated.priorOffsets[IntentClass.translation.rawValue] = 1.2
            contaminated.weights[FeatureID.collectMode.rawValue] = -2
            contaminated.mutes = ["translation|example.app"]
            contaminated.userLanguages = ["DE-de", "en", "de"]
            let frozen = IntentConfig.studyConfiguration(
                userLanguages: contaminated.userLanguages)
            let pass = frozen.isFrozenStudyConfiguration
                && frozen.tier == "balanced"
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
