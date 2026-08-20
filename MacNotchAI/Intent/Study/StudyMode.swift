import Foundation

// THESIS (study instrumentation, M5) — the switch that turns a normal build into a
// study instrument, and the identity that makes its data attributable.
//
// The formative phase lost the session-to-participant mapping because nothing in the
// artefacts recorded who produced which trace. That is a marked deliverable
// (organised, systematic collection of primary research data), so the evaluation
// build stamps a participant id into every trace header and every affordance log line
// at the source.
//
// STUDY MODE ALSO DISABLES AUTO-UPDATE. The research branch is cut from v1.1.3 while
// the public appcast advertises v1.1.5, so a live updater would find a "newer" build
// and replace the study instrument with one that has no Intent pipeline at all —
// silently, mid-deployment, on a participant's own machine. Not publishing the study
// build is necessary but NOT sufficient; the updater has to be off from inside.
enum StudyMode {

    private static let activeKey       = "studyModeActive"
    private static let participantKey  = "studyParticipantID"
    private static let consentKey      = "studyConsentAccepted"
    private static let consentAtKey    = "studyConsentAcceptedAt"
    private static let startedAtKey    = "studyStartedAt"
    private static let summonHintPendingKey = "studySummonHintPending"
    private static let participantLanguagesKey = "studyParticipantLanguages"
    private static let deploymentSnapshotKey = "studyDeploymentSnapshot.v1"

    /// Current consent text version. Bump when the wording changes so the log records
    /// which version a participant actually agreed to.
    static let consentVersion = 4

    // MARK: State

    /// Study instrument mode. While true: auto-update is disabled, the participant id
    /// is stamped into all output, and the status indicator appears in the menu.
    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    /// Pseudonymous participant identifier (e.g. "P03"). Never a name or an email —
    /// the mapping from id to person lives only in the researcher's offline records.
    static var participantID: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: participantKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        set {
            let clean = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set((clean?.isEmpty == false) ? clean : nil, forKey: participantKey)
        }
    }

    /// Reports whether the current wording was accepted. This is provenance/readiness
    /// state only: an already-active deployment is not stopped merely because a later
    /// build contains a newer consent version.
    static var hasConsented: Bool {
        UserDefaults.standard.integer(forKey: consentKey) >= consentVersion
    }

    static var consentAcceptedAt: TimeInterval? {
        let v = UserDefaults.standard.double(forKey: consentAtKey)
        return v > 0 ? v : nil
    }

    /// The version actually accepted, not the currently compiled version.
    static var acceptedConsentVersion: Int? {
        let value = UserDefaults.standard.integer(forKey: consentKey)
        return value > 0 ? value : nil
    }

    /// When this participant's deployment began — drives the "day N" status readout.
    static var startedAt: TimeInterval? {
        let v = UserDefaults.standard.double(forKey: startedAtKey)
        return v > 0 ? v : nil
    }

    /// 1-based day index of the deployment, for the menu status line.
    static var dayIndex: Int? {
        guard let started = startedAt else { return nil }
        return Int((MonotonicClock.wallNow - started) / 86_400) + 1
    }

    /// Set for each newly prepared deployment and cleared only after the healthy
    /// affordance surface has actually shown the onboarding hint. This survives the
    /// Accessibility approval round-trip and a relaunch during researcher setup.
    static var summonHintPending: Bool {
        UserDefaults.standard.bool(forKey: summonHintPendingKey)
    }

    /// Separate from the hand-editable scorer file so a relaunch can reconstruct the
    /// frozen study config even if that file was changed after researcher-led setup.
    static var participantLanguages: [String] {
        get { UserDefaults.standard.stringArray(forKey: participantLanguagesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: participantLanguagesKey) }
    }

    /// Immutable provenance for the deployment that produced the current trace cohort.
    /// It deliberately survives withdrawal: the hand-editable/current scorer config may
    /// change afterwards, but a later export must still contain the exact model and
    /// participant languages that generated the completed study's scores.
    struct DeploymentSnapshot: Codable, Equatable {
        let schemaVersion: Int
        let participantID: String
        let consentVersion: Int
        let consentAcceptedAt: TimeInterval
        let startedAt: TimeInterval
        let configuration: IntentConfig
    }

    static var deploymentSnapshot: DeploymentSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: deploymentSnapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(DeploymentSnapshot.self, from: data)
    }

    static func markSummonHintShown() {
        UserDefaults.standard.set(false, forKey: summonHintPendingKey)
    }

    // MARK: Transitions

    /// Records consent and arms the study build. Called once, at onboarding, with the
    /// researcher present — never silently.
    static func acceptConsent(participantID id: String,
                              configuration: IntentConfig) throws {
        let now = MonotonicClock.wallNow
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty, configuration.isFrozenStudyConfiguration,
              !configuration.userLanguages.isEmpty else {
            throw SnapshotError.invalidConfiguration
        }
        let snapshot = DeploymentSnapshot(
            schemaVersion: 1,
            participantID: cleanID,
            consentVersion: consentVersion,
            consentAcceptedAt: now,
            startedAt: now,
            configuration: configuration)
        let encoded: Data
        do { encoded = try JSONEncoder().encode(snapshot) }
        catch { throw SnapshotError.encodingFailed(error.localizedDescription) }

        // Persist the complete snapshot before arming StudyMode. A crash can therefore
        // leave either a complete, exportable deployment identity or no active study;
        // never an active recorder whose configuration provenance exists only in RAM.
        UserDefaults.standard.set(encoded, forKey: deploymentSnapshotKey)
        participantID = id
        participantLanguages = configuration.userLanguages
        UserDefaults.standard.set(consentVersion, forKey: consentKey)
        UserDefaults.standard.set(now, forKey: consentAtKey)
        // Study setup archives the prior cohort, so every accepted setup is also a new
        // deployment clock even on a researcher-reused pilot installation.
        UserDefaults.standard.set(now, forKey: startedAtKey)
        UserDefaults.standard.set(true, forKey: summonHintPendingKey)
        isActive = true
    }

    enum SnapshotError: LocalizedError {
        case invalidConfiguration
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfiguration:
                return "The study configuration is not frozen or has no participant languages."
            case .encodingFailed(let why):
                return "Could not preserve the study configuration snapshot: \(why)"
            }
        }
    }

    /// Ends participation. Capture stops; collected data is left on disk untouched so
    /// the participant can still export it (or ask for it to be destroyed).
    static func withdraw() {
        isActive = false
        UserDefaults.standard.set(false, forKey: summonHintPendingKey)
    }

    // MARK: Stamping

    /// Fields stamped into every trace header and affordance log line, so a file is
    /// self-describing even if it is separated from its folder.
    static var stampFields: [String: String] {
        var f: [String: String] = [
            "boot": MonotonicClock.sessionID,
            "session": MonotonicClock.sessionID,
            "process": String(MonotonicClock.processID),
        ]
        if let id = participantID { f["participant"] = id }
        if isActive { f["study"] = "true" }
        if let version = acceptedConsentVersion {
            f["consent_version"] = String(version)
        }
        if let acceptedAt = consentAcceptedAt {
            f["consent_accepted_at"] = String(format: "%.3f", acceptedAt)
        }
        return f
    }
}
