import AppKit

// THESIS — manual, verified study export. Live handles are flushed first; the source
// is snapshotted into a private staging directory; only parseable, non-empty JSONL is
// included; every required copy and the resulting archive are verified.
@MainActor
enum StudyExporter {

    enum ExportError: LocalizedError {
        case nothingRecorded
        case invalidJSONL(String)
        case missingRequiredFile(String)
        case captureUnavailable(String)
        case copyFailed(String)
        case zipFailed(String)
        case archiveVerificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .nothingRecorded: return "No valid recorded data was found yet."
            case .invalidJSONL(let name): return "Recorded file is empty or invalid JSONL: \(name)"
            case .missingRequiredFile(let name): return "Required study file is missing: \(name)"
            case .captureUnavailable(let why):
                return "The active study capture is not healthy enough to export: \(why)"
            case .copyFailed(let why): return "Could not snapshot study data: \(why)"
            case .zipFailed(let why): return "Could not create the archive: \(why)"
            case .archiveVerificationFailed(let why): return "Archive verification failed: \(why)"
            }
        }
    }

    static func exportToDesktop() throws -> URL {
        let studyIsActive = StudyMode.isActive
        if studyIsActive,
           IntentEngine.shared.scorer.config != IntentConfig.studyConfiguration(
                userLanguages: StudyMode.participantLanguages) {
            throw ExportError.copyFailed(
                "IntentConfig is not the frozen study configuration; export stopped")
        }
        let deployment = try validatedDeploymentSnapshot(activeStudy: studyIsActive)
        let exportConfiguration = try configurationForExport(
            activeStudy: studyIsActive,
            currentConfiguration: IntentEngine.shared.scorer.config,
            deployment: deployment)
        let incompleteCaptureWarnings = try prepareWritersForSnapshot(
            activeStudy: studyIsActive)

        let fm = FileManager.default
        let traces = TraceRecorder.tracesDirectory()
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: traces,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw ExportError.copyFailed(error.localizedDescription)
        }

        let jsonl = contents.filter { $0.pathExtension.lowercased() == "jsonl" }
        var validJSONL: [URL] = []
        var validTraceCount = 0
        var actionLifecycleAudit: ActionLifecycleAudit?
        for source in jsonl {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw ExportError.invalidJSONL(source.lastPathComponent)
            }
            // A zero-byte artefact has no evidence and is omitted. Any non-empty
            // malformed source is a visible export failure, never silently filtered.
            guard (values.fileSize ?? 0) > 0 else { continue }
            switch try validateJSONL(source) {
            case .valid:
                validJSONL.append(source)
                if source.lastPathComponent.hasPrefix("trace-") { validTraceCount += 1 }
                if source.lastPathComponent == "affordance-log.jsonl" {
                    actionLifecycleAudit = try auditActionLifecycles(in: source)
                }
            case .recoveryOnly:
                // Recovery-only metadata has no behavioural event and therefore does
                // not satisfy `nothingRecorded`, but it is a required audit artefact
                // whenever another valid trace exists.
                validJSONL.append(source)
            case .headerOnly where source.lastPathComponent.hasPrefix("trace-"):
                // A clean relaunch segment before its first event contains no evidence;
                // omitting it must not block export of older valid segments.
                continue
            case .headerOnly, .invalid:
                throw ExportError.invalidJSONL(source.lastPathComponent)
            }
        }
        guard validTraceCount > 0 else { throw ExportError.nothingRecorded }

        let affordanceName = "affordance-log.jsonl"
        if studyIsActive {
            guard validJSONL.contains(where: { $0.lastPathComponent == affordanceName }) else {
                throw ExportError.missingRequiredFile(affordanceName)
            }
        }

        let participant = deployment.participantID
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let bundleName = "dragaway-study-\(safeFileComponent(participant))-\(stamp.string(from: Date()))"
        let staging = fm.temporaryDirectory.appendingPathComponent(bundleName, isDirectory: true)
        if fm.fileExists(atPath: staging.path) {
            do { try fm.removeItem(at: staging) }
            catch { throw ExportError.copyFailed(error.localizedDescription) }
        }
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { throw ExportError.copyFailed(error.localizedDescription) }
        defer { try? fm.removeItem(at: staging) }

        var copied: [URL] = []
        for source in validJSONL.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            copied.append(try copyCanonicalJSONL(source, to: staging))
        }

        if let probe = contents.first(where: { $0.lastPathComponent == "ax-probe-results.txt" }) {
            let values = try probe.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, (values.fileSize ?? 0) > 0 {
                copied.append(try copyVerified(probe, to: staging))
            }
        }

        // Active capture exports the exact validated in-memory scorer configuration.
        // After withdrawal, that mutable runtime is no longer authoritative: export
        // uses the durable deployment snapshot captured before recording was armed.
        let configURL = staging.appendingPathComponent("IntentConfig.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(exportConfiguration)
            guard !data.isEmpty else {
                throw ExportError.missingRequiredFile("valid IntentConfig.json")
            }
            try data.write(to: configURL, options: [.atomic])
            let decoded = try JSONDecoder().decode(IntentConfig.self,
                                                   from: Data(contentsOf: configURL))
            guard decoded == exportConfiguration else {
                throw ExportError.copyFailed("IntentConfig.json differs from deployment snapshot")
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.copyFailed("IntentConfig.json: \(error.localizedDescription)")
        }
        copied.append(configURL)

        let manifestURL = staging.appendingPathComponent("MANIFEST.txt")
        let manifest = try buildManifest(files: copied, deployment: deployment,
                                         incompleteCaptureWarnings: incompleteCaptureWarnings,
                                         actionLifecycleAudit: actionLifecycleAudit)
        do { try manifest.write(to: manifestURL, atomically: true, encoding: .utf8) }
        catch { throw ExportError.copyFailed(error.localizedDescription) }
        copied.append(manifestURL)

        try verifyStaging(copied, under: staging)

        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let archive = uniqueURL(desktop.appendingPathComponent("\(bundleName).zip"))
        do {
            try zip(directory: staging, to: archive)
            try verifyArchive(archive)
        } catch {
            try? fm.removeItem(at: archive)
            throw error
        }
        return archive
    }

    /// A deployment snapshot is the durable bridge between live capture and a later
    /// participant-controlled export. It is never cleared on withdrawal and cannot be
    /// reconstructed from whatever configuration happens to be loaded afterwards.
    private static func validatedDeploymentSnapshot(activeStudy: Bool) throws
        -> StudyMode.DeploymentSnapshot {
        guard let deployment = StudyMode.deploymentSnapshot else {
            throw ExportError.missingRequiredFile("frozen study deployment snapshot")
        }
        guard deployment.schemaVersion == 1,
              !deployment.participantID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deployment.consentVersion > 0,
              deployment.consentAcceptedAt.isFinite, deployment.consentAcceptedAt > 0,
              deployment.startedAt.isFinite, deployment.startedAt > 0,
              deployment.configuration.isFrozenStudyConfiguration,
              !deployment.configuration.userLanguages.isEmpty else {
            throw ExportError.copyFailed("frozen study deployment snapshot is invalid")
        }
        if activeStudy {
            guard StudyMode.participantID == deployment.participantID,
                  StudyMode.acceptedConsentVersion == deployment.consentVersion,
                  StudyMode.consentAcceptedAt == deployment.consentAcceptedAt,
                  StudyMode.startedAt == deployment.startedAt,
                  StudyMode.participantLanguages == deployment.configuration.userLanguages else {
                throw ExportError.copyFailed(
                    "active study identity differs from its frozen deployment snapshot")
            }
        }
        return deployment
    }

    private static func configurationForExport(
        activeStudy: Bool,
        currentConfiguration: IntentConfig,
        deployment: StudyMode.DeploymentSnapshot
    ) throws -> IntentConfig {
        if activeStudy {
            guard currentConfiguration == deployment.configuration else {
                throw ExportError.copyFailed(
                    "live scorer configuration differs from its frozen deployment snapshot")
            }
            return currentConfiguration
        }
        return deployment.configuration
    }

    /// An active study may never export around an unhealthy trace writer. The
    /// affordance writer is allowed to be cleanly stopped because a persisted pause,
    /// sleep/inactivity gate, or paused relaunch deliberately leaves that handle closed;
    /// `flushLog()` then verifies that the canonical on-disk log exists. After withdraw,
    /// no live handle is required: healthy open writers are flushed, stopped writers are
    /// already durable, and failed writers become an explicit partial-export warning.
    private static func prepareWritersForSnapshot(activeStudy: Bool) throws -> [String] {
        let recorder = IntentEngine.shared.recorder
        let affordances = IntentEngine.shared.affordances

        if activeStudy {
            guard recorder.isRecording, recorder.health == .recording else {
                throw ExportError.captureUnavailable(
                    "trace recorder is \(recorderStatus(recorder.health))")
            }
            do { try recorder.flush() }
            catch {
                throw ExportError.captureUnavailable(
                    "trace recorder flush failed: \(oneLine(error.localizedDescription))")
            }

            do { try affordances.flushLog() }
            catch {
                throw ExportError.captureUnavailable(
                    "affordance log flush failed: \(oneLine(error.localizedDescription))")
            }
            return []
        }

        var warnings: [String] = []
        switch recorder.health {
        case .recording:
            do { try recorder.flush() }
            catch {
                warnings.append("Trace recorder failure: \(oneLine(error.localizedDescription))")
            }
        case .failed(let message):
            warnings.append("Trace recorder failure: \(oneLine(message))")
        case .stopped:
            break
        }

        switch affordances.logHealth.state {
        case .healthy:
            do { try affordances.flushLog() }
            catch {
                warnings.append("Affordance log failure: \(oneLine(error.localizedDescription))")
            }
        case .failed:
            warnings.append("Affordance log failure: " + oneLine(
                affordances.logHealth.error ?? "unknown writer failure"))
        case .stopped:
            // Expected after a clean withdrawal or a relaunch while capture is paused.
            break
        }
        return warnings
    }

    private static func recorderStatus(_ health: TraceRecorder.Health) -> String {
        switch health {
        case .recording: return "recording"
        case .stopped: return "stopped"
        case .failed(let message): return "failed (\(oneLine(message)))"
        }
    }

    private static func oneLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Structural JSON is not enough for a research artefact: `{}` is valid JSON but
    /// unusable data. Trace line 1 must be a real v4 study header and every later line
    /// a semantically matching SignalEvent. Every affordance line must satisfy the v4
    /// mandatory schema, study provenance, and numerical bounds.
    private enum JSONLValidation: Equatable { case valid, recoveryOnly, headerOnly, invalid }
    private enum JSONLKind { case trace, affordance, traceRecovery, affordanceRecovery }

    private struct TraceEnvelope: Codable {
        struct Header: Codable {
            struct Recovery: Codable {
                let file: String
                let action: String
                let affectedBytes: UInt64
                let recoveredWallTime: TimeInterval
            }

            let v: Int
            let app: String
            let startedWallTime: TimeInterval
            let startedUptime: TimeInterval
            let day: String
            let sessionID: String
            let processID: Int32
            let study: [String: String]
            let recoveredTails: [Recovery]
        }
        let header: Header
    }

    private struct RecoveryJournalEnvelope: Codable {
        let v: Int
        let recovery: TraceEnvelope.Header.Recovery
    }

    private struct AffordanceRecoveryEnvelope: Codable {
        let v: Int
        let action: String
        let affectedBytes: UInt64
        let recoveredWallTime: TimeInterval
    }

    private struct AffordanceEnvelope: Codable {
        struct ClassScore: Codable {
            let intentClass: String
            let logOdds: Double
            let probability: Double
        }
        struct Evidence: Codable {
            let intentClass: String
            let featureID: String
            let observedAt: Double
            let rawStrength: Double
            let ageSeconds: Double
            let tauSeconds: Double
            let decay: Double
            let weight: Double
            let weightedContribution: Double
        }

        let schemaVersion: Int
        let recordType: String
        let logSessionID: String
        let event: String
        let t: Double
        let wall: Double
        let loggedUptime: Double
        let boot: String
        let sessionID: String
        let processID: Int32
        let participant: String?
        let study: Bool
        let consentVersion: Int?
        let consentAcceptedAt: Double?

        let interactionID: String?
        let channel: String?
        let rank: Int?
        let intentClass: String?
        let probability: Double?
        let action: String?
        let targetKind: String?
        let targetItemCount: Int?
        let latencySeconds: Double?
        let reason: String?
        let passiveWasSilent: Bool?
        let actionable: Bool?
        let actionableCount: Int?
        let rowCount: Int?

        let promptOutcome: String?
        let promptQuestion: String?
        let promptRelevant: Bool?
        let promptUseful: Bool?
        let promptIntrusive: Bool?
        let promptContext: String?
        let promptAnsweredStage: String?
        let promptSkipped: String?

        let recoveryAffectedBytes: UInt64?

        let exposureThreshold: Double
        let classScores: [ClassScore]
        let evidence: [Evidence]
    }

    private struct SuggestionKey: Hashable {
        let interactionID: String
        let channel: String
        let rank: Int
        let intentClass: String
        let probability: Double
        let action: String
        let targetKind: String
        let targetItemCount: Int?

        var promptKey: PromptKey {
            PromptKey(interactionID: interactionID, channel: channel, rank: rank,
                      intentClass: intentClass, action: action)
        }
    }

    private struct PromptKey: Hashable {
        let interactionID: String
        let channel: String
        let rank: Int
        let intentClass: String
        let action: String
    }

    /// Snapshot-time accounting for lifecycle rows that are intentionally legal at a
    /// crash/process boundary. Keeping them valid preserves the evidence that exists;
    /// counting them in the manifest prevents an interrupted delivery/provider turn
    /// from disappearing behind an otherwise successful schema validation.
    private struct ActionLifecycleAudit: Equatable {
        var acceptedWithoutActionStart = 0
        var actionStartedWithoutTerminal = 0
        var controllerStoppedRightCensored = 0

        mutating func finishSession(accepted: Set<SuggestionKey>,
                                    started: Set<SuggestionKey>,
                                    terminated: Set<SuggestionKey>) {
            acceptedWithoutActionStart += accepted.subtracting(started).count
            actionStartedWithoutTerminal += started.subtracting(terminated).count
        }
    }

    private static func validateJSONL(_ url: URL) throws -> JSONLValidation {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return .invalid }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let kind = jsonlKind(for: url.lastPathComponent) else { return .invalid }
        return validateJSONLData(data, kind: kind)
    }

    private static func jsonlKind(for name: String) -> JSONLKind? {
        if name == "trace-recovery-journal.jsonl" { return .traceRecovery }
        if name == "affordance-recovery-journal.jsonl" { return .affordanceRecovery }
        if name.hasPrefix("trace-") { return .trace }
        if name == "affordance-log.jsonl" { return .affordance }
        return nil
    }

    private static func validateJSONLData(_ data: Data, kind: JSONLKind) -> JSONLValidation {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return .invalid }
        guard data.last == 0x0A else { return .invalid }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return .invalid }
        let decoder = JSONDecoder()

        switch kind {
        case .trace:
            guard let header = try? decoder.decode(TraceEnvelope.self,
                                                   from: Data(lines[0].utf8)),
                  validTraceHeader(header.header) else { return .invalid }
            guard lines.count > 1 else {
                return header.header.recoveredTails.isEmpty ? .headerOnly : .recoveryOnly
            }
            var previous: SignalEvent?
            for raw in lines.dropFirst() {
                guard let event = try? decoder.decode(SignalEvent.self, from: Data(raw.utf8)),
                      validSignalEvent(event, header: header.header),
                      validTraceTransition(from: previous, to: event) else { return .invalid }
                previous = event
            }
            return .valid

        case .affordance:
            var records: [AffordanceEnvelope] = []
            for raw in lines {
                guard let record = try? decoder.decode(AffordanceEnvelope.self,
                                                       from: Data(raw.utf8)),
                      validAffordanceRecord(record) else { return .invalid }
                records.append(record)
            }
            return validAffordanceSequence(records) ? .valid : .invalid

        case .traceRecovery:
            for raw in lines {
                guard let row = try? decoder.decode(RecoveryJournalEnvelope.self,
                                                    from: Data(raw.utf8)),
                      row.v == 1, validRecovery(row.recovery) else { return .invalid }
            }
            return .recoveryOnly

        case .affordanceRecovery:
            for raw in lines {
                guard let row = try? decoder.decode(AffordanceRecoveryEnvelope.self,
                                                    from: Data(raw.utf8)),
                      validAffordanceRecovery(row) else { return .invalid }
            }
            return .recoveryOnly
        }
    }

    private static func validTraceHeader(_ header: TraceEnvelope.Header) -> Bool {
        let study = header.study
        guard header.v == 4,
              !header.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              header.startedWallTime.isFinite, header.startedWallTime > 0,
              header.startedUptime.isFinite, header.startedUptime >= 0,
              header.day.count == 8, header.day.allSatisfy(\.isNumber),
              UUID(uuidString: header.sessionID) != nil,
              header.processID > 0,
              study["study"] == "true",
              study["participant"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              study["boot"] == header.sessionID,
              study["session"] == header.sessionID,
              study["process"] == String(header.processID),
              study["consent_version"].flatMap(Int.init).map({ $0 > 0 }) == true,
              study["consent_accepted_at"].flatMap(Double.init).map({ $0.isFinite && $0 > 0 }) == true,
              Set(study.keys) == Set(["boot", "session", "process", "participant",
                                      "study", "consent_version", "consent_accepted_at"]),
              header.recoveredTails.allSatisfy(validRecovery) else { return false }
        return true
    }

    private static func validRecovery(_ recovery: TraceEnvelope.Header.Recovery) -> Bool {
        recovery.file.hasPrefix("trace-") && recovery.file.hasSuffix(".jsonl")
            && !recovery.file.contains("/")
            && ["completed_valid_tail_missing_newline", "discarded_incomplete_tail"]
                .contains(recovery.action)
            && recovery.affectedBytes > 0
            && recovery.recoveredWallTime.isFinite
            && recovery.recoveredWallTime > 0
    }

    private static func validAffordanceRecovery(_ recovery: AffordanceRecoveryEnvelope) -> Bool {
        recovery.v == 1
            && ["completed_valid_tail_missing_newline", "discarded_incomplete_tail"]
                .contains(recovery.action)
            && recovery.affectedBytes > 0
            && recovery.recoveredWallTime.isFinite
            && recovery.recoveredWallTime > 0
    }

    private static func validSignalEvent(_ event: SignalEvent,
                                         header: TraceEnvelope.Header) -> Bool {
        guard event.t.isFinite, event.t >= 0,
              let wall = event.wallTime, wall.isFinite, wall > 0,
              let uptime = event.uptime, uptime.isFinite, uptime >= 0, event.t == uptime,
              event.sessionID == header.sessionID,
              event.processID == header.processID,
              validDiscontinuity(event.clockDiscontinuity, wall: wall, uptime: uptime) else {
            return false
        }
        let payloads = [event.clipboard != nil, event.appFocus != nil, event.scroll != nil,
                        event.dwell != nil, event.selection != nil, event.activity != nil]
        guard payloads.filter({ $0 }).count == 1 else { return false }
        switch event.kind {
        case .clipboard:
            guard let p = event.clipboard else { return false }
            let classes = Set(["text", "url", "image", "files"])
            let shapes = Set(["prose", "code", "table", "list", "question", "fragment"])
            let hashIsValid = p.contentClass == "image" ? p.hashPrefix.isEmpty
                                                        : isHashPrefix(p.hashPrefix)
            guard classes.contains(p.contentClass), p.charCount >= 0, p.wordCount >= 0,
                  validConfidence(p.langConfidence), hashIsValid,
                  p.sourceApp.map({ !$0.isEmpty }) != false,
                  p.embedding?.isEmpty != true,
                  p.embedding?.allSatisfy(\.isFinite) ?? true else { return false }
            switch p.contentClass {
            case "text":
                return p.charCount > 0 && shapes.contains(p.shape)
                    && p.fileExtensions == nil
            case "url":
                return p.charCount > 0 && p.wordCount == 1 && p.language == nil
                    && p.langConfidence == nil && !p.isForeignLanguage && p.shape.isEmpty
                    && p.hasURL && p.fileExtensions == nil && p.embedding == nil
            case "files":
                return p.charCount == 0 && p.wordCount == 0 && p.language == nil
                    && p.langConfidence == nil && !p.isForeignLanguage && p.shape.isEmpty
                    && !p.hasURL && p.fileExtensions?.isEmpty == false && p.embedding == nil
            case "image":
                return p.charCount == 0 && p.wordCount == 0 && p.language == nil
                    && p.langConfidence == nil && !p.isForeignLanguage && p.shape.isEmpty
                    && !p.hasURL && p.fileExtensions == nil && p.embedding == nil
            default:
                return false
            }
        case .appFocus:
            guard let p = event.appFocus else { return false }
            let categories = Set(["browser", "translator", "pdf", "notes", "editor",
                                  "mail", "messaging", "ide", "terminal", "spreadsheet",
                                  "other"])
            guard !p.bundleID.isEmpty, !p.appName.isEmpty, categories.contains(p.category),
                  p.secondsInPrevious.map({ $0.isFinite && $0 >= 0 }) != false else {
                return false
            }
            switch p.transition {
            case "baseline":
                return p.previousBundleID == nil && p.secondsInPrevious == nil
            case "segment_end":
                return p.previousBundleID == p.bundleID && p.secondsInPrevious != nil
            case "activated":
                return (p.previousBundleID == nil) == (p.secondsInPrevious == nil)
                    && p.previousBundleID.map({ !$0.isEmpty }) != false
            default:
                return false
            }
        case .scrollBurst:
            guard let p = event.scroll else { return false }
            return p.duration.isFinite && p.duration >= 0
                && p.netDeltaY.isFinite && p.totalAbsDeltaY.isFinite
                && p.totalAbsDeltaY >= 4 && p.totalAbsDeltaY + 0.1 >= abs(p.netDeltaY)
                && p.directionChanges >= 0 && p.app.map({ !$0.isEmpty }) != false
        case .dwell:
            guard let p = event.dwell else { return false }
            return p.seconds.isFinite && p.seconds >= 10
                && p.app.map({ !$0.isEmpty }) != false
        case .selection:
            guard let p = event.selection else { return false }
            let shapes = Set(["prose", "code", "table", "list", "question", "fragment"])
            let textSelection = p.charCount >= 3 && p.wordCount >= 0
                && shapes.contains(p.shape) && isHashPrefix(p.hashPrefix)
            // The browser-translator transition is a context marker, not selected
            // content, and intentionally carries an empty shape/hash and zero counts.
            let translatorMarker = p.isTranslatorContext && p.charCount == 0
                && p.wordCount == 0 && p.shape.isEmpty && p.hashPrefix.isEmpty
            return (textSelection || translatorMarker)
                && validConfidence(p.langConfidence)
                && p.docID.map({ isHashPrefix($0) }) != false
                && p.app.map({ !$0.isEmpty }) != false
        case .activity:
            guard let p = event.activity else { return false }
            let states = Set(["inactive", "extended_inactivity", "active", "paused",
                              "resumed", "sleep", "wake", "capture_failed",
                              "terminated", "withdrawn", "accessibility_unavailable",
                              "accessibility_restored"])
            return states.contains(p.state) && p.seconds.isFinite && p.seconds >= 0
        }
    }

    private static func validTraceTransition(from previous: SignalEvent?,
                                             to event: SignalEvent) -> Bool {
        guard let previous else { return true }
        let reset = event.clockDiscontinuity?.kind == .uptimeReset
        guard reset ? event.t < previous.t : event.t >= previous.t else { return false }
        if let discontinuity = event.clockDiscontinuity {
            guard let priorWall = previous.wallTime, let priorUptime = previous.uptime else {
                return false
            }
            return discontinuity.previousWallTime == priorWall
                && discontinuity.previousUptime == priorUptime
        }
        guard let wall = event.wallTime, let uptime = event.uptime,
              let priorWall = previous.wallTime, let priorUptime = previous.uptime else {
            return false
        }
        // A >1 s offset change is exactly what MonotonicClock must annotate. Smaller
        // scheduler/clock quantisation remains ordinary monotonic progression.
        return abs((wall - priorWall) - (uptime - priorUptime)) <= 1
    }

    private static func validDiscontinuity(_ value: MonotonicClock.Discontinuity?,
                                           wall: Double, uptime: Double) -> Bool {
        guard let value else { return true }
        return value.detectedWallTime.isFinite && value.detectedWallTime == wall
            && value.previousWallTime.isFinite && value.previousWallTime > 0
            && value.previousUptime.isFinite && value.previousUptime >= 0
            && value.currentUptime.isFinite && value.currentUptime == uptime
            && value.wallMinusUptimeDelta.isFinite
    }

    private static func validConfidence(_ value: Double?) -> Bool {
        value.map { $0.isFinite && (0...1).contains($0) } ?? true
    }

    private static func isHashPrefix(_ value: String) -> Bool {
        value.count == 16 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func validAffordanceRecord(_ record: AffordanceEnvelope) -> Bool {
        let allowedClasses = Set(IntentClass.allCases.map(\.rawValue))
        let scoreClasses = Set(record.classScores.map(\.intentClass))
        let allowedEvents = Set(["session_boundary", "tail_recovery", "blocked", "shown",
                                 "summon", "ticker_closed", "accepted", "accept_failed",
                                 "dismissed", "ignored", "cancelled", "action_started",
                                 "action_completed", "action_failed", "action_cancelled",
                                 "summon_hint_shown",
                                 "prompt"])
        guard record.schemaVersion == 4,
              ["session_boundary", "affordance_event"].contains(record.recordType),
              (record.event == "session_boundary") == (record.recordType == "session_boundary"),
              UUID(uuidString: record.logSessionID) != nil,
              allowedEvents.contains(record.event),
              record.t.isFinite, record.t >= 0,
              record.wall.isFinite, record.wall > 0,
              record.loggedUptime.isFinite, record.loggedUptime >= 0,
              record.loggedUptime + 0.001 >= record.t,
              UUID(uuidString: record.boot) != nil,
              record.sessionID == record.boot, record.processID > 0,
              record.study, record.participant?.isEmpty == false,
              record.consentVersion.map({ $0 > 0 }) == true,
              record.consentAcceptedAt.map({ $0.isFinite && $0 > 0 }) == true,
              record.interactionID.map({ UUID(uuidString: $0) != nil }) != false,
              record.channel.map({ ["passive", "summon"].contains($0) }) != false,
              validRank(record),
              record.intentClass.map({ allowedClasses.contains($0) }) != false,
              record.probability.map({ $0.isFinite && (0...1).contains($0) }) != false,
              record.action.map({ AIAction(rawValue: $0) != nil }) != false,
              record.targetKind.map({ ["pasteboard", "selection", "document",
                                      "clipboard_vault"].contains($0) }) != false,
              record.targetItemCount.map({ (2...3).contains($0) }) != false,
              (record.targetKind == "clipboard_vault") == (record.targetItemCount != nil),
              record.latencySeconds.map({ $0.isFinite && $0 >= 0 }) != false,
              record.reason.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) != false,
              record.actionableCount.map({ $0 >= 0 }) != false,
              record.rowCount.map({ $0 >= 0 }) != false,
              record.actionableCount.map({ count in
                  record.rowCount.map({ count <= $0 }) ?? false
              }) != false,
              record.promptOutcome.map({ ["accepted", "dismissed"].contains($0) }) != false,
              record.promptQuestion.map({ ["suggestion_relevant", "result_useful"].contains($0) }) != false,
              record.promptAnsweredStage.map({ ["none", "assessment",
                                                "assessment+intrusive"].contains($0) }) != false,
              record.promptContext.map({ InSituPrompt.contextOptions.contains($0) }) != false,
              validAffordanceReason(record),
              validPromptSkip(record),
              record.recoveryAffectedBytes.map({ $0 > 0 }) != false,
              (record.event == "tail_recovery") == (record.recoveryAffectedBytes != nil),
              record.exposureThreshold.isFinite,
              (0...1).contains(record.exposureThreshold),
              record.classScores.count == allowedClasses.count,
              scoreClasses == allowedClasses,
              record.classScores.allSatisfy({
                  $0.logOdds.isFinite && $0.probability.isFinite
                      && (0...1).contains($0.probability)
                      && approximatelyEqual($0.probability,
                          1 / (1 + exp(-$0.logOdds)))
              }),
              record.evidence.allSatisfy({
                  guard let feature = FeatureID(rawValue: $0.featureID) else { return false }
                  return $0.intentClass == feature.intentClass.rawValue
                      && $0.observedAt.isFinite && $0.rawStrength.isFinite
                      && (0...1).contains($0.rawStrength)
                      && $0.observedAt <= record.t
                      && $0.ageSeconds.isFinite && $0.ageSeconds >= 0
                      && $0.tauSeconds.isFinite && $0.tauSeconds > 0
                      && $0.decay.isFinite && (0...1).contains($0.decay)
                      && $0.weight.isFinite
                      && $0.weightedContribution.isFinite
                      && approximatelyEqual($0.ageSeconds,
                                            max(0, record.t - $0.observedAt))
                      && approximatelyEqual($0.decay,
                                            exp(-$0.ageSeconds / $0.tauSeconds))
                      && approximatelyEqual($0.weightedContribution,
                                            $0.weight * $0.rawStrength * $0.decay)
              }),
              validAffordanceShape(record) else { return false }
        return true
    }

    private static let controllerStopReasons = Set([
        "controller_stopped", "trace_recorder_failed", "read_only", "paused",
        "extended_inactivity", "sleep", "terminated", "withdrawn",
    ])

    /// Every producer writes categorical reason codes. Keeping this an exact enum-like
    /// contract prevents a future error description, file path or content fragment from
    /// being smuggled through a known Codable field and into an otherwise canonical export.
    private static func validAffordanceReason(_ record: AffordanceEnvelope) -> Bool {
        switch record.event {
        case "session_boundary": return record.reason == "controller_started"
        case "tail_recovery":
            return record.reason.map({
                $0 == "completed_valid_tail_missing_newline"
                    || $0 == "discarded_incomplete_tail"
            }) == true
        case "blocked":
            return record.reason.map({
                ["quiet context", "cooldown after dismiss/ignore",
                 "hourly rate limit (6/h)", "stale_or_replaced_candidate"].contains($0)
            }) == true
        case "ticker_closed", "cancelled":
            return record.reason.map({
                controllerStopReasons.contains($0) || $0 == "user_closed" || $0 == "timeout"
            }) == true
        case "ignored":
            return record.reason == nil || record.reason == "displaced"
        case "accept_failed":
            return record.reason.map({
                ["pasteboard_replaced", "session_start_failed", "target_changed_or_expired",
                 "materialize_failed", "unknown_failure"].contains($0)
                    || controllerStopReasons.contains($0)
            }) == true
        case "action_failed": return record.reason == "provider_or_extraction_error"
        case "action_cancelled":
            return record.reason.map({ value in
                if value == "session_cancelled_or_replaced" { return true }
                guard value.hasPrefix("controller_stopped:") else { return false }
                return controllerStopReasons.contains(String(value.dropFirst("controller_stopped:".count)))
            }) == true
        default: return record.reason == nil
        }
    }

    private static func validPromptSkip(_ record: AffordanceEnvelope) -> Bool {
        guard record.event == "prompt" else { return record.promptSkipped == nil }
        guard let skipped = record.promptSkipped else { return true }
        let fixed = Set(["timeout", "skipped", "displaced_by_passive",
                         "displaced_by_summon", "displaced_by_hint",
                         "displaced_by_new_prompt", "inactive_before_display",
                         "quota_changed_before_display"])
        return fixed.contains(skipped) || controllerStopReasons.contains(skipped)
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = max(1, max(abs(lhs), abs(rhs)))
        return abs(lhs - rhs) <= 1e-10 * scale
    }

    private static func validAffordanceShape(_ record: AffordanceEnvelope) -> Bool {
        let hasInteraction = record.interactionID != nil
        let hasSuggestion = hasInteraction && record.channel != nil && record.rank.map({ $0 > 0 }) == true
            && record.intentClass != nil && record.probability != nil
            && record.action != nil && record.targetKind != nil
        switch record.event {
        case "session_boundary":
            return record.reason == "controller_started" && !hasInteraction
        case "tail_recovery":
            return record.reason.map({
                $0 == "completed_valid_tail_missing_newline"
                    || $0 == "discarded_incomplete_tail"
            }) == true && record.recoveryAffectedBytes != nil && !hasInteraction
        case "blocked":
            return hasInteraction && record.channel == "passive" && record.rank == 1
                && record.intentClass == IntentClass.translation.rawValue
                && record.probability != nil && record.reason != nil
                && record.action == nil && record.targetKind == nil
        case "summon":
            return hasInteraction && record.channel == "summon" && record.rank == 0
                && record.intentClass != nil && record.probability != nil
                && record.passiveWasSilent != nil && record.action == nil
        case "shown":
            if record.channel == "passive" { return hasSuggestion }
            guard record.channel == "summon", hasInteraction,
                  record.rank.map({ $0 > 0 }) == true,
                  record.intentClass != nil, record.probability != nil,
                  let actionable = record.actionable,
                  record.actionableCount != nil, record.rowCount.map({ $0 > 0 }) == true else {
                return false
            }
            return actionable ? hasSuggestion : (record.action == nil && record.targetKind == nil)
        case "ticker_closed":
            return hasInteraction && record.channel == "summon" && record.rank == 0
                && record.reason != nil && record.actionableCount != nil
                && record.rowCount != nil
        case "accepted", "dismissed", "ignored", "cancelled":
            return hasSuggestion && record.latencySeconds != nil
        case "accept_failed":
            return hasSuggestion && record.reason != nil
        case "action_started":
            return hasSuggestion && record.latencySeconds == nil && record.reason == nil
        case "action_completed":
            return hasSuggestion && record.latencySeconds != nil && record.reason == nil
        case "action_failed":
            return hasSuggestion && record.latencySeconds != nil
                && record.reason == "provider_or_extraction_error"
        case "action_cancelled":
            return hasSuggestion && record.latencySeconds != nil
                && record.reason.map({
                    $0 == "session_cancelled_or_replaced"
                        || $0.hasPrefix("controller_stopped:")
                }) == true
        case "summon_hint_shown":
            return hasInteraction && record.channel == nil && record.rank == nil
                && record.intentClass == nil && record.action == nil
        case "prompt":
            guard hasInteraction, record.channel != nil, record.rank.map({ $0 > 0 }) == true,
                  record.intentClass != nil, record.action != nil,
                  let outcome = record.promptOutcome, let question = record.promptQuestion,
                  let stage = record.promptAnsweredStage else {
                return false
            }
            if question == "result_useful" && outcome != "accepted" { return false }
            let expectedFirst = question == "result_useful"
                ? record.promptUseful : record.promptRelevant
            let unexpectedFirst = question == "result_useful"
                ? record.promptRelevant : record.promptUseful
            guard unexpectedFirst == nil else { return false }
            switch stage {
            case "none":
                return expectedFirst == nil && record.promptIntrusive == nil
                    && record.promptContext == nil && record.promptSkipped != nil
            case "assessment":
                return expectedFirst != nil && record.promptIntrusive == nil
                    && record.promptContext == nil && record.promptSkipped != nil
            case "assessment+intrusive":
                guard expectedFirst != nil, record.promptIntrusive != nil else { return false }
                return (record.promptContext != nil) != (record.promptSkipped != nil)
            default:
                return false
            }
        default:
            return false
        }
    }

    private static func validAffordanceSequence(_ records: [AffordanceEnvelope]) -> Bool {
        guard !records.isEmpty else { return false }
        var currentLog: String?
        var session: (boot: String, process: Int32, participant: String,
                      consent: Int, acceptedAt: Double)?
        var seenLogs = Set<String>()
        var lastT = -Double.infinity
        var summons = Set<String>()
        var actionableShown = Set<SuggestionKey>()
        var outcomes = Set<SuggestionKey>()
        var promptEligible: [PromptKey: (outcome: String, question: String)] = [:]
        var prompted = Set<PromptKey>()
        var accepted = Set<SuggestionKey>()
        var actionStarted = Set<SuggestionKey>()
        var actionTerminated = Set<SuggestionKey>()

        for record in records {
            if record.event == "session_boundary" {
                guard !seenLogs.contains(record.logSessionID),
                      let participant = record.participant,
                      let consent = record.consentVersion,
                      let acceptedAt = record.consentAcceptedAt else { return false }
                seenLogs.insert(record.logSessionID)
                currentLog = record.logSessionID
                session = (record.boot, record.processID, participant, consent, acceptedAt)
                lastT = record.t
                summons.removeAll(keepingCapacity: true)
                actionableShown.removeAll(keepingCapacity: true)
                outcomes.removeAll(keepingCapacity: true)
                promptEligible.removeAll(keepingCapacity: true)
                prompted.removeAll(keepingCapacity: true)
                accepted.removeAll(keepingCapacity: true)
                actionStarted.removeAll(keepingCapacity: true)
                actionTerminated.removeAll(keepingCapacity: true)
                continue
            }
            guard record.logSessionID == currentLog, let session,
                  record.boot == session.boot, record.processID == session.process,
                  record.participant == session.participant,
                  record.consentVersion == session.consent,
                  record.consentAcceptedAt == session.acceptedAt,
                  record.t >= lastT else { return false }
            lastT = record.t

            guard let id = record.interactionID else {
                if record.event != "tail_recovery" { return false }
                continue
            }
            switch record.event {
            case "summon":
                guard summons.insert(id).inserted else { return false }
            case "shown":
                if record.channel == "summon", !summons.contains(id) { return false }
                if record.actionable != false {
                    guard let key = suggestionKey(record),
                          actionableShown.insert(key).inserted else { return false }
                }
            case "ticker_closed":
                if !summons.contains(id) { return false }
            case "accepted", "accept_failed", "dismissed", "ignored", "cancelled":
                guard let key = suggestionKey(record), actionableShown.contains(key),
                      outcomes.insert(key).inserted else { return false }
                if record.event == "accepted" {
                    accepted.insert(key)
                } else if record.event == "dismissed" {
                    guard promptEligible[key.promptKey] == nil else { return false }
                    promptEligible[key.promptKey] = ("dismissed", "suggestion_relevant")
                }
            case "action_started":
                guard let key = suggestionKey(record), accepted.contains(key),
                      actionStarted.insert(key).inserted else { return false }
            case "action_completed", "action_failed", "action_cancelled":
                guard let key = suggestionKey(record), actionStarted.contains(key),
                      actionTerminated.insert(key).inserted,
                      promptEligible[key.promptKey] == nil else { return false }
                if record.event != "action_cancelled" {
                    promptEligible[key.promptKey] = (
                        "accepted",
                        record.event == "action_completed" ? "result_useful" : "suggestion_relevant")
                }
            case "prompt":
                guard let key = promptKey(record),
                      let eligible = promptEligible[key],
                      eligible.outcome == record.promptOutcome,
                      eligible.question == record.promptQuestion,
                      prompted.insert(key).inserted else { return false }
            case "blocked", "summon_hint_shown": break
            default: return false
            }
        }
        return currentLog != nil
    }

    private static func auditActionLifecycles(in url: URL) throws -> ActionLifecycleAudit {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.last == 0x0A, let text = String(data: data, encoding: .utf8) else {
            throw ExportError.invalidJSONL(url.lastPathComponent)
        }
        let decoder = JSONDecoder()
        let records = try text.split(separator: "\n", omittingEmptySubsequences: true).map {
            try decoder.decode(AffordanceEnvelope.self, from: Data($0.utf8))
        }
        return actionLifecycleAudit(records)
    }

    private static func actionLifecycleAudit(_ records: [AffordanceEnvelope])
        -> ActionLifecycleAudit {
        var audit = ActionLifecycleAudit()
        var accepted = Set<SuggestionKey>()
        var started = Set<SuggestionKey>()
        var terminated = Set<SuggestionKey>()
        var hasSession = false

        func finishCurrentSession() {
            guard hasSession else { return }
            audit.finishSession(accepted: accepted, started: started,
                                terminated: terminated)
        }

        for record in records {
            if record.event == "session_boundary" {
                finishCurrentSession()
                accepted.removeAll(keepingCapacity: true)
                started.removeAll(keepingCapacity: true)
                terminated.removeAll(keepingCapacity: true)
                hasSession = true
                continue
            }
            guard let key = suggestionKey(record) else { continue }
            switch record.event {
            case "accepted":
                accepted.insert(key)
            case "action_started":
                started.insert(key)
            case "action_completed", "action_failed", "action_cancelled":
                terminated.insert(key)
                if record.event == "action_cancelled",
                   record.reason?.hasPrefix("controller_stopped:") == true {
                    audit.controllerStoppedRightCensored += 1
                }
            default:
                break
            }
        }
        finishCurrentSession()
        return audit
    }

    private static func suggestionKey(_ record: AffordanceEnvelope) -> SuggestionKey? {
        guard let interactionID = record.interactionID,
              let channel = record.channel, let rank = record.rank,
              let intentClass = record.intentClass, let probability = record.probability,
              let action = record.action, let targetKind = record.targetKind else { return nil }
        return SuggestionKey(interactionID: interactionID, channel: channel, rank: rank,
                             intentClass: intentClass, probability: probability,
                             action: action, targetKind: targetKind,
                             targetItemCount: record.targetItemCount)
    }

    private static func promptKey(_ record: AffordanceEnvelope) -> PromptKey? {
        guard let interactionID = record.interactionID,
              let channel = record.channel, let rank = record.rank,
              let intentClass = record.intentClass, let action = record.action else { return nil }
        return PromptKey(interactionID: interactionID, channel: channel, rank: rank,
                         intentClass: intentClass, action: action)
    }

    private static func validRank(_ record: AffordanceEnvelope) -> Bool {
        guard let rank = record.rank else { return true }
        if ["summon", "ticker_closed"].contains(record.event) { return rank == 0 }
        guard rank > 0 else { return false }
        if let rowCount = record.rowCount, rowCount > 0 { return rank <= rowCount }
        return true
    }

#if THESIS_STUDY_BUILD
    /// Small pure seam for CI/golden checks without touching the user's trace folder.
    static func schemaValidationCheckForTesting() -> Bool {
        let session = "11111111-1111-4111-8111-111111111111"
        let header: [String: Any] = ["header": [
            "v": 4, "app": "test", "startedWallTime": 1_700_000_000.0,
            "startedUptime": 100.0, "day": "20260812", "sessionID": session,
            "processID": 42, "study": ["study": "true", "participant": "P-test",
                "boot": session, "session": session, "process": "42",
                "consent_version": "2", "consent_accepted_at": "1700000000.0"],
            "recoveredTails": [] as [Any],
        ]]
        let event: [String: Any] = [
            "t": 101.0, "kind": "activity", "wallTime": 1_700_000_001.0,
            "uptime": 101.0, "sessionID": session, "processID": 42,
            "activity": ["state": "active", "seconds": 1.0],
        ]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header),
              let eventData = try? JSONSerialization.data(withJSONObject: event) else {
            return false
        }
        var trace = Data()
        trace.append(headerData)
        trace.append(0x0A)
        trace.append(eventData)
        trace.append(0x0A)
        guard case .valid = validateJSONLData(trace, kind: .trace),
              case .invalid = validateJSONLData(Data("{}\n".utf8), kind: .affordance) else {
            return false
        }

        let logSession = "22222222-2222-4222-8222-222222222222"
        let interaction = "33333333-3333-4333-8333-333333333333"
        let scores: [[String: Any]] = IntentClass.allCases.map {
            ["intentClass": $0.rawValue, "logOdds": 0.0, "probability": 0.5]
        }
        func base(_ event: String, _ type: String, _ t: Double) -> [String: Any] {
            ["schemaVersion": 4, "recordType": type, "logSessionID": logSession,
             "event": event, "t": t, "wall": 1_700_000_000.0 + t,
             "loggedUptime": t, "boot": session, "sessionID": session,
             "processID": 42, "participant": "P-test", "study": true,
             "consentVersion": 3, "consentAcceptedAt": 1_700_000_000.0,
             "exposureThreshold": 0.7, "classScores": scores,
             "evidence": [] as [Any]]
        }
        var boundary = base("session_boundary", "session_boundary", 200)
        boundary["reason"] = "controller_started"
        var shown = base("shown", "affordance_event", 201)
        shown.merge(["interactionID": interaction, "channel": "passive", "rank": 1,
                     "intentClass": "translation", "probability": 0.5,
                     "action": "Translate to English", "targetKind": "pasteboard",
                     "rawText": "must-not-leave-staging"], uniquingKeysWith: { _, new in new })
        var accepted = base("accepted", "affordance_event", 202)
        accepted.merge(["interactionID": interaction, "channel": "passive", "rank": 1,
                        "intentClass": "translation", "probability": 0.5,
                        "action": "Translate to English", "targetKind": "pasteboard",
                        "latencySeconds": 1.0], uniquingKeysWith: { _, new in new })
        var actionStarted = base("action_started", "affordance_event", 203)
        actionStarted.merge(["interactionID": interaction, "channel": "passive", "rank": 1,
                             "intentClass": "translation", "probability": 0.5,
                             "action": "Translate to English", "targetKind": "pasteboard"],
                            uniquingKeysWith: { _, new in new })
        var actionCompleted = base("action_completed", "affordance_event", 204)
        actionCompleted.merge(["interactionID": interaction, "channel": "passive", "rank": 1,
                               "intentClass": "translation", "probability": 0.5,
                               "action": "Translate to English", "targetKind": "pasteboard",
                               "latencySeconds": 1.5], uniquingKeysWith: { _, new in new })
        var prompt = base("prompt", "affordance_event", 205)
        prompt.merge(["interactionID": interaction, "channel": "passive", "rank": 1,
                      "intentClass": "translation", "action": "Translate to English",
                      "promptOutcome": "accepted", "promptQuestion": "result_useful",
                      "promptUseful": true,
                      "promptIntrusive": false, "promptContext": "Writing",
                      "promptAnsweredStage": "assessment+intrusive"],
                     uniquingKeysWith: { _, new in new })

        func jsonl(_ rows: [[String: Any]]) -> Data? {
            var data = Data()
            for row in rows {
                guard let encoded = try? JSONSerialization.data(withJSONObject: row) else {
                    return nil
                }
                data.append(encoded)
                data.append(0x0A)
            }
            return data
        }
        guard let validAffordance = jsonl(
                  [boundary, shown, accepted, actionStarted, actionCompleted, prompt]),
              case .valid = validateJSONLData(validAffordance, kind: .affordance),
              let canonical = try? canonicalJSONL(validAffordance, kind: .affordance),
              !String(decoding: canonical, as: UTF8.self).contains("rawText") else {
            return false
        }
        var wrongRank = accepted
        wrongRank["rank"] = 2
        guard let invalidLink = jsonl([boundary, shown, wrongRank]),
              case .invalid = validateJSONLData(invalidLink, kind: .affordance) else {
            return false
        }
        var poisonedKnownField = shown
        poisonedKnownField["reason"] = "/Users/example/private-document.txt"
        guard let invalidReason = jsonl([boundary, poisonedKnownField]),
              case .invalid = validateJSONLData(invalidReason, kind: .affordance) else {
            return false
        }

        // A lifecycle boundary may cancel an in-flight AX/materialisation accept.
        // This is a legitimate, content-free failure row and must not poison export.
        var stoppedAccept = accepted
        stoppedAccept["event"] = "accept_failed"
        stoppedAccept["reason"] = "sleep"
        stoppedAccept.removeValue(forKey: "latencySeconds")
        guard let stoppedAcceptLog = jsonl([boundary, shown, stoppedAccept]),
              case .valid = validateJSONLData(stoppedAcceptLog, kind: .affordance) else {
            return false
        }

        var actionCancelled = base("action_cancelled", "affordance_event", 204)
        actionCancelled.merge([
            "interactionID": interaction, "channel": "passive", "rank": 1,
            "intentClass": "translation", "probability": 0.5,
            "action": "Translate to English", "targetKind": "pasteboard",
            "latencySeconds": 1.0, "reason": "controller_stopped:sleep",
        ], uniquingKeysWith: { _, new in new })
        guard let acceptedOnly = jsonl([boundary, shown, accepted]),
              let startedOnly = jsonl([boundary, shown, accepted, actionStarted]),
              let censored = jsonl([boundary, shown, accepted, actionStarted,
                                    actionCancelled]),
              case .valid = validateJSONLData(acceptedOnly, kind: .affordance),
              case .valid = validateJSONLData(startedOnly, kind: .affordance),
              case .valid = validateJSONLData(censored, kind: .affordance),
              let acceptedOnlyRecords = decodeAffordanceRowsForTesting(acceptedOnly),
              let startedOnlyRecords = decodeAffordanceRowsForTesting(startedOnly),
              let censoredRecords = decodeAffordanceRowsForTesting(censored),
              actionLifecycleAudit(acceptedOnlyRecords) == ActionLifecycleAudit(
                acceptedWithoutActionStart: 1,
                actionStartedWithoutTerminal: 0,
                controllerStoppedRightCensored: 0),
              actionLifecycleAudit(startedOnlyRecords) == ActionLifecycleAudit(
                acceptedWithoutActionStart: 0,
                actionStartedWithoutTerminal: 1,
                controllerStoppedRightCensored: 0),
              actionLifecycleAudit(censoredRecords) == ActionLifecycleAudit(
                acceptedWithoutActionStart: 0,
                actionStartedWithoutTerminal: 0,
                controllerStoppedRightCensored: 1) else {
            return false
        }
        return true
    }

    private static func decodeAffordanceRowsForTesting(_ data: Data)
        -> [AffordanceEnvelope]? {
        let decoder = JSONDecoder()
        return try? String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(AffordanceEnvelope.self, from: Data($0.utf8)) }
    }

    /// Proves that a completed deployment exports its persisted configuration rather
    /// than mutable post-withdraw runtime state, and that active capture still requires
    /// exact equality with the same snapshot.
    static func deploymentSnapshotCheckForTesting() -> Bool {
        let frozen = IntentConfig.studyConfiguration(userLanguages: ["de", "en"])
        let snapshot = StudyMode.DeploymentSnapshot(
            schemaVersion: 1,
            participantID: "P-golden",
            consentVersion: StudyMode.consentVersion,
            consentAcceptedAt: 1_700_000_000,
            startedAt: 1_700_000_000,
            configuration: frozen)
        guard let encoded = try? JSONEncoder().encode(snapshot),
              let decoded = try? JSONDecoder().decode(
                StudyMode.DeploymentSnapshot.self, from: encoded),
              decoded == snapshot else { return false }

        var changedAfterWithdraw = frozen
        changedAfterWithdraw.tier = "aggressive"
        changedAfterWithdraw.userLanguages = ["fr"]
        guard let completedExport = try? configurationForExport(
                activeStudy: false,
                currentConfiguration: changedAfterWithdraw,
                deployment: decoded),
              completedExport == frozen,
              let liveExport = try? configurationForExport(
                activeStudy: true,
                currentConfiguration: frozen,
                deployment: decoded),
              liveExport == frozen else { return false }

        do {
            _ = try configurationForExport(
                activeStudy: true,
                currentConfiguration: changedAfterWithdraw,
                deployment: decoded)
            return false
        } catch {
            return true
        }
    }
#endif

    /// Decode and re-encode the typed rows before staging. This is a privacy boundary,
    /// not cosmetic formatting: Swift's decoder ignores unknown keys, so copying the
    /// source bytes could otherwise export an injected `rawText`/path field even after
    /// all known fields validated successfully.
    private static func copyCanonicalJSONL(_ source: URL, to directory: URL) throws -> URL {
        guard let kind = jsonlKind(for: source.lastPathComponent) else {
            throw ExportError.invalidJSONL(source.lastPathComponent)
        }
        let sourceData = try Data(contentsOf: source, options: [.mappedIfSafe])
        let canonical = try canonicalJSONL(sourceData, kind: kind)
        guard !canonical.isEmpty else { throw ExportError.invalidJSONL(source.lastPathComponent) }

        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do { try canonical.write(to: destination, options: [.atomic]) }
        catch { throw ExportError.copyFailed("\(source.lastPathComponent): \(error.localizedDescription)") }
        guard (try? Data(contentsOf: destination)) == canonical else {
            throw ExportError.copyFailed("canonical snapshot mismatch for \(source.lastPathComponent)")
        }
        let result = try validateJSONL(destination)
        guard result == .valid || result == .recoveryOnly else {
            throw ExportError.invalidJSONL(destination.lastPathComponent)
        }
        return destination
    }

    private static func canonicalJSONL(_ data: Data, kind: JSONLKind) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExportError.invalidJSONL("non-UTF8 JSONL")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()

        func append<T: Encodable>(_ value: T) throws {
            output.append(try encoder.encode(value))
            output.append(0x0A)
        }
        switch kind {
        case .trace:
            guard let first = lines.first else { throw ExportError.invalidJSONL("trace") }
            try append(decoder.decode(TraceEnvelope.self, from: Data(first.utf8)))
            for line in lines.dropFirst() {
                try append(decoder.decode(SignalEvent.self, from: Data(line.utf8)))
            }
        case .affordance:
            for line in lines {
                try append(decoder.decode(AffordanceEnvelope.self, from: Data(line.utf8)))
            }
        case .traceRecovery:
            for line in lines {
                try append(decoder.decode(RecoveryJournalEnvelope.self, from: Data(line.utf8)))
            }
        case .affordanceRecovery:
            for line in lines {
                try append(decoder.decode(AffordanceRecoveryEnvelope.self, from: Data(line.utf8)))
            }
        }
        return output
    }

    private static func copyVerified(_ source: URL, to directory: URL,
                                     named name: String? = nil) throws -> URL {
        let destination = directory.appendingPathComponent(name ?? source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { throw ExportError.copyFailed("\(source.lastPathComponent): \(error.localizedDescription)") }
        let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let destinationSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard sourceSize == destinationSize, (destinationSize ?? 0) > 0 else {
            throw ExportError.copyFailed("size mismatch for \(source.lastPathComponent)")
        }
        return destination
    }

    private static func verifyStaging(_ files: [URL], under staging: URL) throws {
        let expected = Set(files.map(\.lastPathComponent))
        let actual = Set(try FileManager.default.contentsOfDirectory(atPath: staging.path))
        guard expected == actual else {
            throw ExportError.copyFailed("staging contents differ from the manifest snapshot")
        }
        for file in files {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw ExportError.copyFailed("empty staged file: \(file.lastPathComponent)") }
        }
    }

    private static func buildManifest(files: [URL],
                                      deployment: StudyMode.DeploymentSnapshot,
                                      incompleteCaptureWarnings: [String],
                                      actionLifecycleAudit: ActionLifecycleAudit?) throws -> String {
        let byteFormatter = ByteCountFormatter()
        var lines = [
            "DRAGAWAY STUDY DATA — what is in this archive",
            String(repeating: "=", count: 60), "",
            "Participant ID:  \(deployment.participantID)",
            "Created:         \(DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short))",
            "Recording began: \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: deployment.startedAt), dateStyle: .long, timeStyle: .short))",
            "Consent version accepted: \(deployment.consentVersion)",
            "Consent accepted: \(DateFormatter.localizedString(from: Date(timeIntervalSince1970: deployment.consentAcceptedAt), dateStyle: .long, timeStyle: .short))",
            "Participant languages: \(deployment.configuration.userLanguages.joined(separator: ", "))",
            "Configuration snapshot schema: \(deployment.schemaVersion)",
        ]
        if !incompleteCaptureWarnings.isEmpty {
            lines += ["", String(repeating: "!", count: 60),
                      "STATUS: INCOMPLETE CAPTURE — PARTIAL EXPORT ONLY",
                      "At least one recording writer reported a failure. Every included JSONL",
                      "file is structurally valid, but events around or after that failure may",
                      "be missing. Do NOT treat this archive as a complete 24-hour recording."]
            lines += incompleteCaptureWarnings.map { "  · \($0)" }
            lines.append(String(repeating: "!", count: 60))
        }
        lines += ["", "ACTION LIFECYCLE AUDIT", String(repeating: "-", count: 60)]
        if let audit = actionLifecycleAudit {
            lines += [
                "  Accepted without action_started: \(audit.acceptedWithoutActionStart)",
                "  action_started without terminal outcome: \(audit.actionStartedWithoutTerminal)",
                "  Controller-stop right-censored actions: \(audit.controllerStoppedRightCensored)",
                "  Open counts can mean an action was live at export or capture ended between rows;",
                "  controller-stop cancellations mean the later provider outcome was not observed.",
            ]
        } else {
            lines.append("  No affordance log was present in this partial export.")
        }
        lines += ["", "FILES", String(repeating: "-", count: 60)]

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let what: String
            switch file.lastPathComponent {
            case "trace-recovery-journal.jsonl": what = "durable trace-tail recovery audit"
            case "affordance-recovery-journal.jsonl": what = "durable affordance-tail recovery audit"
            case let n where n.hasPrefix("trace-"): what = "interaction signals for one recording segment"
            case "affordance-log.jsonl": what = "suggestions, outcomes, prompts, and model evidence"
            case "ax-probe-results.txt": what = "technical Accessibility coverage checks"
            case "IntentConfig.json": what = "the scorer settings used during recording"
            default: what = "supporting data"
            }
            lines.append("  \(file.lastPathComponent) · \(byteFormatter.string(fromByteCount: Int64(size))) · \(what)")
        }
        lines += ["  MANIFEST.txt · this file", "",
                  "WHAT THE DATA CONTAINS", String(repeating: "-", count: 60),
                  """
                    · wall-clock and process-uptime timings, app identities and activity-gap markers
                    · text measurements (length, language, shape), never the raw text
                    · short fingerprints used to recognise repeated text/documents
                    · numerical sentence-embedding vectors derived from copied text; these support
                      topic-similarity analysis and may retain information about the source text
                    · suggestions, model evidence, responses, and in-situ ratings
                  """, "", "WHAT IT DOES NOT CONTAIN", String(repeating: "-", count: 60),
                  """
                    · no raw text you read, wrote, copied or selected
                    · no screenshots, keystrokes or passwords
                    · no web addresses, file paths or document names
                    · no content from periods explicitly paused
                  """, "", "HONEST NOTE ON ANONYMITY", String(repeating: "-", count: 60),
                  """
                  This content-minimised behavioural record is NOT anonymous. Hashes permit
                  membership tests, numerical embeddings may be partially invertible, and work
                  patterns can identify a person. It is therefore treated as personal data, sent
                  only by you, used only for this dissertation, and deleted no later than twelve
                  months after submission. If you never send this archive, no data is used.
                  """, ""]
        return lines.joined(separator: "\n")
    }

    private static func zip(directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: [.forUploading],
                                       error: &coordinationError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw ExportError.zipFailed(coordinationError.localizedDescription) }
        if let copyError { throw ExportError.zipFailed(copyError.localizedDescription) }
    }

    private static func verifyArchive(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize > 22 else {
            throw ExportError.archiveVerificationFailed("archive is missing or empty")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let signature = try handle.read(upToCount: 4) ?? Data()
            guard Array(signature) == [0x50, 0x4B, 0x03, 0x04] else {
                throw ExportError.archiveVerificationFailed("file does not start with a ZIP entry")
            }

            // A leading PK marker alone also exists in truncated archives. Validate
            // the end-of-central-directory record and its bounds as a completeness
            // check (study archives are far below ZIP64 limits).
            let tailCount = min(fileSize, 65_557)
            try handle.seek(toOffset: UInt64(fileSize - tailCount))
            let tail = [UInt8](try handle.read(upToCount: tailCount) ?? Data())
            guard tail.count >= 22,
                  let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                      tail[$0] == 0x50 && tail[$0 + 1] == 0x4B &&
                      tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06
                  }) else {
                throw ExportError.archiveVerificationFailed("ZIP directory footer is missing")
            }
            let entries = Int(littleEndian16(tail, eocd + 10))
            let directorySize = Int(littleEndian32(tail, eocd + 12))
            let directoryOffset = Int(littleEndian32(tail, eocd + 16))
            let commentLength = Int(littleEndian16(tail, eocd + 20))
            let absoluteEOCD = fileSize - tail.count + eocd
            guard entries > 0,
                  eocd + 22 + commentLength == tail.count,
                  directoryOffset + directorySize <= absoluteEOCD else {
                throw ExportError.archiveVerificationFailed("ZIP directory is incomplete")
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.archiveVerificationFailed(error.localizedDescription)
        }
    }

    private static func littleEndian16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func safeFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let clean = raw.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : Character("-")
        }
        let value = String(clean).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "unassigned" : String(value.prefix(48))
    }

    private static func uniqueURL(_ candidate: URL) -> URL {
        var url = candidate
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            url = candidate.deletingLastPathComponent().appendingPathComponent("\(base)-\(n).zip")
            n += 1
        }
        return url
    }
}
