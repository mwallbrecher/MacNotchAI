import Foundation

// THESIS (L3) — the log-linear Bayes scorer. docs/thesis/ARCHITECTURE.md §5.
//
//   S_c(t) = basePrior + priorOffset_c + Σ_i w_i · strength_i · e^−(t−t_i)/τ_i
//   P(c|E) = σ(S_c)
//
// Weights are log-likelihood-ratios (w = +2.2 ⇒ signal ~9× likelier under real
// intent). The prior (≈ −3.9 = logit 0.02) makes silence the ground state. Decay is
// ANALYTIC AND LAZY: a pure function of the read time — no timers tick for scoring,
// and replayed traces score identically because everything runs on event time.
//
// The additive breakdown IS the explanation ("why this suggestion?") — the
// transparency requirement as an architectural property, not an afterthought.

// MARK: - Config (all tunables live here — values are data, not architecture)

struct IntentConfig: Codable, Equatable {
    var v = 1
    /// "lazy" | "balanced" | "aggressive" — exposure tier (M3 policy reads this).
    var tier = "balanced"
    /// logit(0.02) ≈ −3.89 — "assistable intent right now" is rare by default.
    var basePriorLogOdds = -3.89
    /// Per-class prior shifts. USER-owned (preference, M4 compiler writes these);
    /// the learner never touches them — see the §9 ownership split.
    var priorOffsets: [String: Double] = [:]
    /// Per-feature log-likelihood-ratio weights. LEARNER-owned from M4 on.
    var weights: [String: Double] = IntentConfig.defaultWeights
    /// Per-feature decay constants τ (seconds).
    var taus: [String: Double] = IntentConfig.defaultTaus
    /// Exposure thresholds per tier (probability domain).
    var thresholds: [String: Double] = ["lazy": 0.85, "balanced": 0.70, "aggressive": 0.55]
    /// Cooldown after an explicit dismiss (ignore = half of this) — ARCHITECTURE §7.
    var dismissCooldownSeconds: Double = 600
    /// Passive-channel rate limit per tier (shows per hour).
    var rateLimits: [String: Int] = ["lazy": 3, "balanced": 6, "aggressive": 12]
    /// "class|bundleID" pairs the user muted ("do not suggest again").
    var mutes: [String] = []
    /// Classes allowed to speak on the PASSIVE channel, i.e. without being summoned.
    /// The product default is translation alone: the noisier classes stay ticker-only
    /// until they have been evaluated on labelled traces (ARCHITECTURE §11). Expressed
    /// as data so a study deployment can widen it without forking the policy.
    var passiveClasses: [String] = [IntentClass.translation.rawValue]
    /// Languages the USER reads comfortably ("de", "en", …). Empty ⇒ derive from the
    /// machine locale. **Must be set explicitly for every study session**: Phase 1 runs
    /// on the researcher's Mac, so participants would otherwise all inherit the
    /// researcher's locale and `foreign_language_clip` would be meaningless. For a
    /// distributed build the locale fallback is the sensible default (refined by the
    /// M4 onboarding question).
    var userLanguages: [String] = []

    // Initial values, tuned against the synthetic design targets (validated by
    // the standalone scorer test; refine against golden traces):
    //   · translation: foreign clip + translator switch ⇒ fires on balanced (~73%);
    //     either signal alone stays silent (12% / 29%). The switch is the strongest
    //     tell (w=3.0 ⇒ LR ≈ e^3 ≈ 20 — the user literally opened a translator).
    //     A confident copy/target language mismatch is independently decisive: unlike
    //     participant-relative "foreignness", it identifies the language required by
    //     the editable destination and therefore crosses balanced on its own.
    //   · comprehension/discovery: noisier signal families — deliberately need
    //     near-max combined evidence to speak unprompted; below that they surface
    //     through the summon ticker until personalization lifts their priors (§9).
    static let defaultWeights: [String: Double] = [
        "foreign_language_clip":        2.2,
        "copy_then_translator_switch":  3.0,
        "copy_target_language_mismatch": 5.0,
        "format_mismatch":              0.8,
        "re_reading":                   2.4,
        "visible_range_revisit":        2.8,
        "dense_dwell":                  1.6,
        "repeat_selection":             2.0,
        "collect_mode":                 2.2,
        "topic_coherence":              2.6,
    ]
    static let defaultTaus: [String: Double] = [
        "foreign_language_clip":        60,
        "copy_then_translator_switch":  60,
        "copy_target_language_mismatch": 60,
        "format_mismatch":              60,
        "re_reading":                  180,
        "visible_range_revisit":       180,
        "dense_dwell":                 180,
        "repeat_selection":            120,
        "collect_mode":                 90,
        "topic_coherence":             120,
    ]

    func weight(for f: FeatureID) -> Double { weights[f.rawValue] ?? Self.defaultWeights[f.rawValue] ?? 1.0 }
    func tau(for f: FeatureID) -> Double { taus[f.rawValue] ?? Self.defaultTaus[f.rawValue] ?? 90 }
    func priorOffset(for c: IntentClass) -> Double { priorOffsets[c.rawValue] ?? 0 }
    var exposureThreshold: Double { thresholds[tier] ?? 0.70 }
    var rateLimitPerHour: Int { rateLimits[tier] ?? 6 }

    // MARK: schema-evolution-safe decoding
    //
    // Synthesized Codable would reject any config file missing a newly added key
    // (keyNotFound) and shunt the user's hand-tuned file into the .broken backup
    // path on every schema growth. decodeIfPresent per field keeps old files valid.

    init() {}

    /// Frozen configuration for an in-situ study deployment. Participant languages
    /// are the sole per-participant input; every inferential and exposure parameter is
    /// reset to the compiled baseline so a reused pilot install cannot leak learned or
    /// hand-edited state into a new cohort.
    /// Names a frozen study baseline. Deployments already in the field were created
    /// under whichever baseline shipped at the time and must still export afterwards,
    /// so cases are APPENDED here and the body of an existing case is never edited.
    enum StudyBaseline: Int, CaseIterable, Sendable {
        /// Product exposure posture: balanced tier, translation-only passive channel.
        case v1 = 1
        /// Study posture, a deliberate inversion of the product's. Shipping, an
        /// unwanted interruption costs trust, so silence is the safe default. In the
        /// experiment a missed offer yields NO observation at all, while a premature
        /// one still yields a labelled event plus the participant's reaction to it —
        /// which is the data the thresholds are supposed to be calibrated against.
        /// Ticker-only classes would likewise never produce the labels needed to
        /// decide whether they belong on the passive channel.
        case v2 = 2

        static let current = StudyBaseline.v2
    }

    static func studyConfiguration(userLanguages: [String],
                                   baseline: StudyBaseline = .current) -> IntentConfig {
        var config = IntentConfig()
        switch baseline {
        case .v1:
            config.tier = "balanced"
            config.passiveClasses = [IntentClass.translation.rawValue]
        case .v2:
            config.tier = "aggressive"
            config.passiveClasses = IntentClass.allCases.map(\.rawValue).sorted()
        }
        config.userLanguages = Array(Set(userLanguages.compactMap { raw in
            let code = String(raw.prefix(2)).lowercased()
            return code.count == 2 && code.allSatisfy(\.isLetter) ? code : nil
        })).sorted()
        return config
    }

    /// Invariant checked before a Study export: this configuration came from SOME
    /// legitimate frozen baseline rather than from learned or hand-edited state. The
    /// selected language repertoire is intentionally preserved while every other field
    /// is compared.
    ///
    /// Deliberately NOT a comparison against the newest baseline. A deployment recorded
    /// weeks ago has to remain exportable after the baseline moves, and checking it
    /// against "whatever this build compiles today" silently invalidated exactly that —
    /// a full day of capture became unexportable the moment the study posture changed.
    var isFrozenStudyConfiguration: Bool {
        StudyBaseline.allCases.contains {
            self == Self.studyConfiguration(userLanguages: userLanguages, baseline: $0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case v, tier, basePriorLogOdds, priorOffsets, weights, taus, thresholds,
             dismissCooldownSeconds, rateLimits, mutes, userLanguages, passiveClasses
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IntentConfig()
        v                      = try c.decodeIfPresent(Int.self, forKey: .v) ?? d.v
        tier                   = try c.decodeIfPresent(String.self, forKey: .tier) ?? d.tier
        basePriorLogOdds       = try c.decodeIfPresent(Double.self, forKey: .basePriorLogOdds) ?? d.basePriorLogOdds
        priorOffsets           = try c.decodeIfPresent([String: Double].self, forKey: .priorOffsets) ?? d.priorOffsets
        weights                = try c.decodeIfPresent([String: Double].self, forKey: .weights) ?? d.weights
        taus                   = try c.decodeIfPresent([String: Double].self, forKey: .taus) ?? d.taus
        thresholds             = try c.decodeIfPresent([String: Double].self, forKey: .thresholds) ?? d.thresholds
        dismissCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .dismissCooldownSeconds) ?? d.dismissCooldownSeconds
        rateLimits             = try c.decodeIfPresent([String: Int].self, forKey: .rateLimits) ?? d.rateLimits
        mutes                  = try c.decodeIfPresent([String].self, forKey: .mutes) ?? d.mutes
        userLanguages          = try c.decodeIfPresent([String].self, forKey: .userLanguages) ?? d.userLanguages
        passiveClasses         = try c.decodeIfPresent([String].self, forKey: .passiveClasses) ?? d.passiveClasses
    }

    /// Normalised repertoire ("DE-de" → "de"); empty ⇒ caller falls back to the locale.
    var normalisedUserLanguages: Set<String> {
        Set(userLanguages
            .map { String($0.prefix(2)).lowercased() }
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) })
    }

    // MARK: persistence — a hand-editable JSON next to the traces

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Dragaway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("IntentConfig.json")
    }

    /// Field-wise validation with clamping. A hand-edited file can contain a
    /// negative τ, an out-of-range threshold, an unknown tier, or (via "1e999")
    /// infinities — none of that may reach the scorer, and none of it may destroy
    /// the user's file. Corrections apply IN MEMORY only; the file stays untouched.
    func validated() -> (config: IntentConfig, corrections: [String]) {
        var c = self
        var notes: [String] = []
        if c.thresholds[c.tier] == nil {
            notes.append("tier '\(c.tier)' unknown → balanced"); c.tier = "balanced"
        }
        if !c.basePriorLogOdds.isFinite || !(-10...2).contains(c.basePriorLogOdds) {
            notes.append("basePriorLogOdds \(c.basePriorLogOdds) → -3.89")
            c.basePriorLogOdds = -3.89
        }
        for (k, v) in c.weights {
            // The destination-language mismatch is intentionally strong enough to
            // cross balanced by itself. Less-direct signals retain the historical
            // tighter guardrail.
            let limit = k == FeatureID.copyTargetLanguageMismatch.rawValue ? 6.0 : 4.0
            guard !v.isFinite || abs(v) > limit else { continue }
            let fixed = v.isFinite ? max(-limit, min(limit, v))
                                   : (Self.defaultWeights[k] ?? 1)
            notes.append("weight \(k)=\(v) → \(fixed)"); c.weights[k] = fixed
        }
        for (k, v) in c.taus where !v.isFinite || v <= 0 || v > 3600 {
            let fixed = Self.defaultTaus[k] ?? 90
            notes.append("tau \(k)=\(v) → \(fixed)"); c.taus[k] = fixed
        }
        for (k, v) in c.thresholds where !v.isFinite || !(0.01...0.99).contains(v) {
            let fixed = k == "lazy" ? 0.85 : (k == "aggressive" ? 0.55 : 0.70)
            notes.append("threshold \(k)=\(v) → \(fixed)"); c.thresholds[k] = fixed
        }
        for (k, v) in c.priorOffsets where !v.isFinite || abs(v) > 1.5 {
            // ±1.5 is the preference-compiler clamp (ARCHITECTURE §9) — hand edits
            // don't get to exceed what the user-control surface allows.
            let fixed = v.isFinite ? max(-1.5, min(1.5, v)) : 0
            notes.append("priorOffset \(k)=\(v) → \(fixed)"); c.priorOffsets[k] = fixed
        }
        if !c.dismissCooldownSeconds.isFinite || !(30...86_400).contains(c.dismissCooldownSeconds) {
            notes.append("dismissCooldownSeconds \(c.dismissCooldownSeconds) → 600")
            c.dismissCooldownSeconds = 600
        }
        for (k, v) in c.rateLimits where !(1...60).contains(v) {
            let fixed = k == "lazy" ? 3 : (k == "aggressive" ? 12 : 6)
            notes.append("rateLimit \(k)=\(v) → \(fixed)"); c.rateLimits[k] = fixed
        }
        let badLangs = c.userLanguages.filter {
            let code = String($0.prefix(2)).lowercased()
            return code.count != 2 || !code.allSatisfy(\.isLetter)
        }
        if !badLangs.isEmpty {
            notes.append("userLanguages dropped invalid: \(badLangs.joined(separator: ","))")
            c.userLanguages = c.userLanguages.filter { !badLangs.contains($0) }
        }
        let knownClasses = Set(IntentClass.allCases.map(\.rawValue))
        let unknownPassive = c.passiveClasses.filter { !knownClasses.contains($0) }
        if !unknownPassive.isEmpty {
            notes.append("passiveClasses dropped unknown: \(unknownPassive.joined(separator: ","))")
            let kept = c.passiveClasses.filter(knownClasses.contains)
            // An explicit [] means "never speak unprompted" and is honoured above,
            // because nothing was dropped. Reaching empty only by dropping unknown
            // names is a typo, and silently muting the passive channel would hide it.
            c.passiveClasses = kept.isEmpty ? IntentConfig().passiveClasses : kept
        }
        return (c, notes)
    }

    /// Loads the config, writing the defaults file on first use so there is always
    /// a concrete JSON to hand-tweak. Invalid FIELDS are corrected in memory (file
    /// untouched); an UNDECODABLE file is backed up — never silently overwritten —
    /// before defaults are regenerated.
    static func load() -> IntentConfig {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = IntentConfig(); fresh.save(); return fresh
        }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(IntentConfig.self, from: data) {
            let (config, corrections) = decoded.validated()
#if DEBUG
            if !corrections.isEmpty {
                print("[intent] config corrections (file left untouched):")
                corrections.forEach { print("  · \($0)") }
            }
#endif
            return config
        }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("IntentConfig.broken-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: backup)
#if DEBUG
        print("[intent] ⚠️ IntentConfig.json undecodable — backed up as \(backup.lastPathComponent), defaults regenerated")
#endif
        let fresh = IntentConfig(); fresh.save(); return fresh
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL())
        }
    }
}

// MARK: - Scorer

final class IntentScorer {

    var config: IntentConfig

    /// Decayed-evidence window; trimmed against evidence time (replay-safe).
    private(set) var evidence: [Evidence] = []
    private let window: TimeInterval = 300   // beyond 5 min everything has decayed to ~0

    init(config: IntentConfig = .load()) {
        self.config = config
    }

    func add(_ e: Evidence) {
        // A detector re-firing the same feature within 5 s refreshes rather than
        // stacks — scroll bursts would otherwise pile up evidence for one behaviour.
        if let last = evidence.lastIndex(where: { $0.feature == e.feature && e.t - $0.t < 5 }) {
            if e.strength >= evidence[last].strength {
                evidence[last] = e
            }
        } else {
            evidence.append(e)
        }
        evidence.removeAll { $0.t < e.t - window }
    }

    /// Removes evidence whose validity is tied to a mutable external object. Most
    /// detector rows naturally decay, but a clipboard/target-language join must stop
    /// contributing as soon as either side of that exact join is replaced.
    func remove(_ feature: FeatureID) {
        evidence.removeAll { $0.feature == feature }
    }

    func reset() { evidence = [] }

    // MARK: Reading scores (lazy decay — evaluated at read time)

    struct Contribution {
        let feature: FeatureID
        let value: Double        // w · strength · decay — one summand of S_c
    }

    struct Breakdown {
        let intentClass: IntentClass
        let logOdds: Double
        let probability: Double
        let contributions: [Contribution]   // sorted, strongest first
    }

    func scores(at t: TimeInterval) -> [Breakdown] {
        IntentClass.allCases.map { c in
            var contributions: [Contribution] = []
            for e in evidence where e.feature.intentClass == c {
                let decay = exp(-(t - e.t) / config.tau(for: e.feature))
                let value = config.weight(for: e.feature) * e.strength * decay
                if value > 0.01 { contributions.append(Contribution(feature: e.feature, value: value)) }
            }
            contributions.sort { $0.value > $1.value }
            let logOdds = config.basePriorLogOdds + config.priorOffset(for: c)
                        + contributions.reduce(0) { $0 + $1.value }
            return Breakdown(intentClass: c,
                             logOdds: logOdds,
                             probability: 1.0 / (1.0 + exp(-logOdds)),
                             contributions: contributions)
        }
        .sorted { $0.probability > $1.probability }
    }

    /// Human-readable score snapshot — the "why" decomposition (M2 acceptance).
    func describeScores(at t: TimeInterval) -> String {
        scores(at: t).map { b in
            let pct = String(format: "%.0f%%", b.probability * 100)
            let s = String(format: "%+.2f", b.logOdds)
            if b.contributions.isEmpty {
                return "\(b.intentClass.rawValue)  \(pct)  (S=\(s), no evidence)"
            }
            let parts = b.contributions.prefix(4)
                .map { "\($0.feature.rawValue) +\(String(format: "%.2f", $0.value))" }
                .joined(separator: ", ")
            return "\(b.intentClass.rawValue)  \(pct)  (S=\(s): \(parts))"
        }
        .joined(separator: "\n")
    }
}
