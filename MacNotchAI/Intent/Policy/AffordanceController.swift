import AppKit
import Carbon.HIToolbox
import SwiftUI

// THESIS (L4/L5 glue) — one controller for the passive whisper and summoned ticker.
// All raw-content access is deferred until accept. The study log is a versioned,
// typed JSONL stream; a write failure disarms the surface rather than silently
// collecting an incomplete interaction history.

extension Notification.Name {
    static let intentAutoRunAction = Notification.Name("com.aidrop.thesis.intentAutoRunAction")
    static let intentAffordanceLogFailed = Notification.Name(
        "com.aidrop.thesis.intentAffordanceLogFailed"
    )
}

struct AffordanceLogHealth: Equatable {
    enum State: String { case stopped, healthy, failed }

    let state: State
    let url: URL?
    let error: String?

    var isHealthy: Bool { state == .healthy }
    var description: String {
        switch state {
        case .healthy: return "healthy · \(url?.lastPathComponent ?? "affordance log")"
        case .stopped: return "stopped · \(url?.lastPathComponent ?? "no log yet")"
        case .failed:  return "failed · \(error ?? "unknown log error")"
        }
    }
}

enum AffordanceLogError: LocalizedError {
    case notOpen
    case createFailed(URL)
    case unhealthy(String)
    case hotkeyRegistrationFailed

    var errorDescription: String? {
        switch self {
        case .notOpen: return "The affordance log is not open."
        case .createFailed(let url): return "Could not create \(url.path)."
        case .unhealthy(let message): return message
        case .hotkeyRegistrationFailed:
            return "The study summon hotkey could not be registered (it may conflict with another app)."
        }
    }
}

private struct AffordanceClassScoreRecord: Codable {
    let intentClass: String
    let logOdds: Double
    let probability: Double
}

private struct AffordanceEvidenceRecord: Codable {
    let intentClass: String
    let featureID: String
    let observedAt: TimeInterval
    let rawStrength: Double
    let ageSeconds: Double
    let tauSeconds: Double
    let decay: Double
    let weight: Double
    let weightedContribution: Double
}

/// Durable audit row written before an interrupted final affordance record is
/// completed or truncated. It survives a second failure while opening the log.
private struct AffordanceTailRecovery: Codable {
    let v: Int
    let action: String
    let affectedBytes: UInt64
    let recoveredWallTime: TimeInterval
}

private struct AffordanceEventRecord: Codable {
    let schemaVersion: Int
    let recordType: String
    let logSessionID: String
    let event: String
    let t: TimeInterval
    let wall: TimeInterval
    let loggedUptime: TimeInterval
    let boot: String
    let sessionID: String
    let processID: Int32
    let participant: String?
    let study: Bool
    let consentVersion: Int?
    let consentAcceptedAt: TimeInterval?

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

    // Experience sampling deliberately asks whether an early suggestion was relevant
    // or wanted. It does not claim an AI result was helpful before completion.
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
    let classScores: [AffordanceClassScoreRecord]
    let evidence: [AffordanceEvidenceRecord]
}

private struct AffordanceLogFields {
    var interactionID: UUID?
    var channel: AffordanceChannel?
    var rank: Int?
    var intentClass: IntentClass?
    var probability: Double?
    var action: String?
    var targetKind: String?
    var targetItemCount: Int?
    var latencySeconds: Double?
    var reason: String?
    var passiveWasSilent: Bool?
    var actionable: Bool?
    var actionableCount: Int?
    var rowCount: Int?
    var promptOutcome: String?
    var promptQuestion: String?
    var promptRelevant: Bool?
    var promptUseful: Bool?
    var promptIntrusive: Bool?
    var promptContext: String?
    var promptAnsweredStage: String?
    var promptSkipped: String?
    var recoveryAffectedBytes: UInt64?

    init(suggestion: IntentSuggestion? = nil) {
        interactionID = suggestion?.interactionID
        channel = suggestion?.channel
        rank = suggestion?.rank
        intentClass = suggestion?.intentClass
        probability = suggestion?.probability
        action = suggestion?.action.rawValue
        targetKind = suggestion?.target.kind
        if case .clipboardVault(let references) = suggestion?.target {
            targetItemCount = references.count
        }
    }
}

@MainActor
final class AffordanceController {

    private unowned let scorer: IntentScorer
    private unowned let extractor: FeatureExtractor
    private var policy: AffordancePolicy

    private var window: WhisperWindow?
    private var current: IntentSuggestion?
    private var shownAt: TimeInterval = 0
    private var fadeTimer: Timer?
    private var tickerVisible = false
    private var tickerTask: Task<Void, Never>?
    private var tickerInteractionID: UUID?
    private var tickerRows: [TickerRow] = []

    private var acceptTask: Task<Void, Never>?
    private var pendingAcceptance: IntentSuggestion?
    /// Provider turns that were started from an accepted affordance in the current
    /// log session. Stop writes their cancellations before closing the handle; stale
    /// async completions from an older session are ignored instead of poisoning the
    /// next session's interaction sequence.
    private var activeActionStarts: [UUID: (suggestion: IntentSuggestion,
                                             startedAt: TimeInterval,
                                             logSessionID: UUID)] = [:]

    private let acceptHotkey = GlobalHotkey()
    private let summonHotkey = GlobalHotkey()
    private let fadeSeconds: TimeInterval = 8
    private let tickerTimeoutSeconds: TimeInterval = 30

    private var logHandle: FileHandle?
    private var logSyncTimer: Timer?
    private var pendingTailRecoveries: [AffordanceTailRecovery] = []
    private var logSessionID = UUID()
    private var lastLogSyncUptime: TimeInterval = 0
    private static let logSyncInterval: TimeInterval = 30
    private(set) var logHealth = AffordanceLogHealth(state: .stopped, url: nil, error: nil)
    var logStatusDescription: String { logHealth.description }
    private var isStarted = false

    init(scorer: IntentScorer, extractor: FeatureExtractor) {
        self.scorer = scorer
        self.extractor = extractor
        policy = AffordancePolicy(mutes: scorer.config.mutes)
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        do {
            try openLog()
            isStarted = true
            var fields = AffordanceLogFields()
            fields.reason = "controller_started"
            guard writeEvent("session_boundary", at: MonotonicClock.now, fields: fields) else {
                return
            }
            for recovery in pendingTailRecoveries {
                var recoveryFields = AffordanceLogFields()
                recoveryFields.reason = recovery.action
                recoveryFields.recoveryAffectedBytes = recovery.affectedBytes
                guard writeEvent("tail_recovery", at: MonotonicClock.now,
                                 fields: recoveryFields) else { return }
            }
            if !pendingTailRecoveries.isEmpty {
                guard let logHandle else { throw AffordanceLogError.notOpen }
                try logHandle.synchronize()
                try Self.clearRecoveryJournal(in: TraceRecorder.ensureTracesDirectory())
                pendingTailRecoveries.removeAll(keepingCapacity: false)
            }
            guard isStarted, logHealth.isHealthy else { return }
            let registered = summonHotkey.register(keyCode: UInt32(kVK_ANSI_I),
                                  modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
                self?.toggleTicker()
            }
            guard registered else {
                failLogging(AffordanceLogError.hotkeyRegistrationFailed)
                return
            }
        } catch {
            failLogging(error)
        }
    }

    /// Preflight used by researcher-led setup. It proves that the global summon
    /// chord is registerable before a 24-hour session is armed, then releases it so
    /// the real controller can own registration together with its log handle.
    func preflightSummonHotkey() -> Bool {
        guard !isStarted, logHandle == nil else { return true }
        let registered = summonHotkey.register(keyCode: UInt32(kVK_ANSI_I),
                                               modifiers: UInt32(controlKey | optionKey | cmdKey)) {}
        summonHotkey.unregister()
        return registered
    }

    func stop(reason stopReason: String = "controller_stopped") {
        IntentAutoRun.shared.clear(logSessionID: logSessionID)
        guard isStarted || logHandle != nil else {
            cancelPendingAcceptance()
            discardPromptState()
            tickerTask?.cancel()
            tickerTask = nil
            fadeTimer?.invalidate()
            fadeTimer = nil
            current = nil
            tickerVisible = false
            tickerRows = []
            tickerInteractionID = nil
            acceptHotkey.unregister()
            summonHotkey.unregister()
            window?.orderOut(nil)
            extractor.clearResolverCandidates()
            IntentContentVault.shared.clear()
            return
        }

        cancelPrompt(reason: stopReason, hideSurface: true)
        cancelActiveActions(reason: stopReason)
        if let suggestion = pendingAcceptance {
            var fields = AffordanceLogFields(suggestion: suggestion)
            fields.reason = stopReason
            _ = writeEvent("accept_failed", at: MonotonicClock.now, fields: fields)
        }
        cancelPendingAcceptance()
        discardPromptState()

        if tickerVisible {
            closeTicker(reason: stopReason)
        } else if let suggestion = current {
            var fields = AffordanceLogFields(suggestion: suggestion)
            fields.reason = stopReason
            fields.latencySeconds = max(0, MonotonicClock.now - shownAt)
            _ = writeEvent("cancelled", at: MonotonicClock.now, fields: fields)
            hideWindow(recordIgnoreIfPending: false)
        } else {
            hideWindow(recordIgnoreIfPending: false)
        }

        tickerTask?.cancel()
        tickerTask = nil
        summonHotkey.unregister()
        logSyncTimer?.invalidate()
        logSyncTimer = nil
        extractor.clearResolverCandidates()
        IntentContentVault.shared.clear()
        isStarted = false

        let priorFailure = logHealth.state == .failed ? logHealth.error : nil
        guard let handle = logHandle else { return }
        var stopError: Error?
        do { try handle.synchronize() }
        catch { stopError = error }
        do { try handle.close() }
        catch { if stopError == nil { stopError = error } }
        logHandle = nil
        lastLogSyncUptime = 0
        if let stopError {
            failLogging(stopError)
        } else if let priorFailure {
            logHealth = AffordanceLogHealth(state: .failed, url: logHealth.url,
                                            error: priorFailure)
        } else {
            logHealth = AffordanceLogHealth(state: .stopped, url: logHealth.url, error: nil)
        }
    }

    /// Export uses this to establish that all lifecycle records reached disk without
    /// closing the live stream. A cleanly stopped controller is already synchronized.
    func flushLog() throws {
        if let handle = logHandle, logHealth.isHealthy {
            do {
                try handle.synchronize()
                lastLogSyncUptime = MonotonicClock.uptimeNow
                return
            } catch {
                failLogging(error)
                throw error
            }
        }
        if logHealth.state == .stopped {
            // Persisted pause and post-withdraw relaunches intentionally do not open a
            // live controller. A canonical log already on disk is therefore a clean,
            // flush-free source; export will still parse every line before including it.
            let url = logHealth.url
                ?? TraceRecorder.tracesDirectory().appendingPathComponent("affordance-log.jsonl")
            if FileManager.default.fileExists(atPath: url.path) { return }
        }
        if let error = logHealth.error { throw AffordanceLogError.unhealthy(error) }
        throw AffordanceLogError.notOpen
    }

    func configReloaded() {
        policy = AffordancePolicy(mutes: scorer.config.mutes)
    }

    /// New participant/pilot boundary: clear every stateful exposure guard as well as
    /// the persisted sampling budget. The scorer configuration is frozen by the engine
    /// immediately before this call.
    func resetForNewStudy() {
        policy = AffordancePolicy(mutes: scorer.config.mutes)
        resetPromptQuotaForNewStudy()
    }

    /// Uptime may pause while the Mac sleeps. Cooldown/rate-limit timestamps therefore
    /// cannot be carried across an explicit sleep boundary without acquiring an unknown
    /// extra duration. Evidence is reset on wake too, so begin a clean exposure segment.
    func resetExposureStateAfterSleep() {
        policy = AffordancePolicy(mutes: scorer.config.mutes)
    }

    // MARK: Passive channel

    func evaluate(at eventTime: TimeInterval) {
        guard isStarted, logHealth.isHealthy,
              current == nil, !tickerVisible, pendingAcceptance == nil else { return }
        // Passive M3 exposes translation only. Using the global top class here can
        // accidentally show a Translation action with a Comprehension probability.
        guard let translation = scorer.scores(at: eventTime).first(where: {
                  $0.intentClass == .translation
              }), translation.probability >= scorer.config.exposureThreshold else { return }

        let interactionID = UUID()
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let verdict = policy.decide(intentClass: .translation,
                                    probability: translation.probability,
                                    frontApp: frontApp,
                                    quietContext: QuietContext.isQuiet(),
                                    at: eventTime, config: scorer.config)
        guard verdict.isShow else {
            if case .silent(let reason) = verdict {
                var fields = AffordanceLogFields()
                fields.interactionID = interactionID
                fields.channel = .passive
                fields.rank = 1
                fields.intentClass = .translation
                fields.probability = translation.probability
                fields.reason = reason
                _ = writeEvent("blocked", at: eventTime, fields: fields)
            }
            return
        }

        guard let suggestion = TaskResolver.resolveTranslation(
            candidate: extractor.translationCandidate(at: eventTime),
            probability: translation.probability,
            interactionID: interactionID, channel: .passive, rank: 1
        ) else {
            var fields = AffordanceLogFields()
            fields.interactionID = interactionID
            fields.channel = .passive
            fields.rank = 1
            fields.intentClass = .translation
            fields.probability = translation.probability
            fields.reason = "stale_or_replaced_candidate"
            _ = writeEvent("blocked", at: eventTime, fields: fields)
            return
        }

        cancelPrompt(reason: "displaced_by_passive", hideSurface: true)
        let displayTime = MonotonicClock.now
        policy.confirmShown(at: displayTime)
        current = suggestion
        shownAt = displayTime
        showWhisper(suggestion)
        _ = writeEvent("shown", at: displayTime,
                       fields: AffordanceLogFields(suggestion: suggestion))
    }

    // MARK: Summoned channel

    func toggleTicker() {
        guard isStarted, logHealth.isHealthy else { return }
        if tickerVisible {
            closeTicker(reason: "user_closed")
            return
        }

        cancelPrompt(reason: "displaced_by_summon", hideSurface: true)
        hideWindow(recordIgnoreIfPending: true)

        let summonTime = MonotonicClock.now
        shownAt = 0
        tickerRows = []
        let interactionID = UUID()
        let top3 = Array(scorer.scores(at: summonTime).prefix(3))
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let passiveSilent = top3.first(where: { $0.intentClass == .translation }).map {
            let policySilent = !policy.decide(intentClass: .translation,
                           probability: $0.probability,
                           frontApp: frontApp,
                           quietContext: QuietContext.isQuiet(),
                           at: summonTime, config: scorer.config).isShow
            let targetUnavailable = TaskResolver.resolveTranslation(
                candidate: extractor.translationCandidate(at: summonTime),
                probability: $0.probability,
                interactionID: interactionID, channel: .passive, rank: 1) == nil
            return policySilent || targetUnavailable
        } ?? true
        var summonFields = AffordanceLogFields()
        summonFields.interactionID = interactionID
        summonFields.channel = .summon
        summonFields.rank = 0
        summonFields.intentClass = top3.first?.intentClass
        summonFields.probability = top3.first?.probability
        summonFields.passiveWasSilent = passiveSilent
        guard writeEvent("summon", at: summonTime, fields: summonFields) else { return }

        // Freeze candidate/vault coordinates before the async AX probe so a copy made
        // while AX is resolving cannot be smuggled into this already-started summon.
        let vault = IntentContentVault.shared.snapshot(at: summonTime)
        let hasFreshClipboard = extractor.latestTextCandidate(at: summonTime)
            .map { TaskResolver.pasteboardMatches($0.hash) } ?? false

        tickerVisible = true
        tickerInteractionID = interactionID
        tickerTask = Task { [weak self] in
            guard let self else { return }
            let ax = await DocumentReader.probe(includeDocumentFallback: !hasFreshClipboard)
            guard !Task.isCancelled, self.isStarted, self.tickerVisible,
                  self.tickerInteractionID == interactionID else { return }

            let context = TaskResolver.makeContext(extractor: self.extractor,
                                                   at: summonTime, ax: ax, vault: vault)
            let rows = top3.enumerated().map { offset, breakdown -> TickerRow in
                let evidence = breakdown.contributions.prefix(2)
                    .map { "\($0.feature.rawValue) +\(String(format: "%.1f", $0.value))" }
                    .joined(separator: " · ")
                let suggestion = TaskResolver.resolve(intentClass: breakdown.intentClass,
                                                      probability: breakdown.probability,
                                                      context: context,
                                                      interactionID: interactionID,
                                                      channel: .summon, rank: offset + 1)
                return TickerRow(intentClass: breakdown.intentClass,
                                 probability: breakdown.probability,
                                 evidenceLine: evidence.isEmpty ? "no live evidence" : evidence,
                                 suggestion: suggestion)
            }

            self.tickerTask = nil
            self.tickerRows = rows
            let displayTime = MonotonicClock.now
            self.shownAt = displayTime
            self.show(content: .ticker(rows), size: CGSize(width: 480, height: 248))

            for (offset, row) in rows.enumerated() {
                var fields = AffordanceLogFields(suggestion: row.suggestion)
                fields.interactionID = interactionID
                fields.channel = .summon
                fields.rank = offset + 1
                fields.intentClass = row.intentClass
                fields.probability = row.probability
                fields.actionable = row.suggestion != nil
                fields.actionableCount = rows.filter { $0.suggestion != nil }.count
                fields.rowCount = rows.count
                guard self.writeEvent("shown", at: displayTime, fields: fields) else {
                    self.hideWindow(recordIgnoreIfPending: false)
                    return
                }
            }
            self.armTickerTimeout()
        }
    }

    private func closeTicker(reason: String) {
        guard tickerVisible else { return }
        tickerTask?.cancel()
        tickerTask = nil
        let t = MonotonicClock.now
        var fields = AffordanceLogFields()
        fields.interactionID = tickerInteractionID
        fields.channel = .summon
        fields.rank = 0
        fields.reason = reason
        fields.latencySeconds = shownAt > 0 ? max(0, t - shownAt) : nil
        fields.actionableCount = tickerRows.filter { $0.suggestion != nil }.count
        fields.rowCount = tickerRows.count
        _ = writeEvent("ticker_closed", at: t, fields: fields)
        hideWindow(recordIgnoreIfPending: false)
    }

    // MARK: Outcomes and verified handoff

    private func accept(_ suggestion: IntentSuggestion) {
        guard pendingAcceptance == nil else { return }
        let requestedAt = MonotonicClock.now
        let latency = max(0, requestedAt - shownAt)
        hideWindow(recordIgnoreIfPending: false)
        pendingAcceptance = suggestion
        acceptTask = Task { [weak self] in
            await self?.completeAccept(suggestion, requestedAt: requestedAt, latency: latency)
        }
    }

    private func completeAccept(_ suggestion: IntentSuggestion,
                                requestedAt: TimeInterval,
                                latency: TimeInterval) async {
        var failure: String?
        var openedRevision: UUID?

        switch suggestion.target {
        case .pasteboard(let hash):
            if !TaskResolver.pasteboardMatches(hash) {
                failure = "pasteboard_replaced"
            } else {
                openedRevision = openClipboardSession(suggestion: suggestion)
                if openedRevision == nil { failure = "session_start_failed" }
            }

        case .accessibility, .clipboardVault:
            guard let text = await TaskResolver.materializedText(for: suggestion.target,
                                                                 at: MonotonicClock.now) else {
                failure = "target_changed_or_expired"
                break
            }
            guard !Task.isCancelled else { return }
            guard let url = DropMaterializer.materialize(.text(text)) else {
                failure = "materialize_failed"
                break
            }
            if case .clipboardVault(let references) = suggestion.target {
                IntentContentVault.shared.discard(references)
            }
            openedRevision = openFileSession(url: url, suggestion: suggestion)
            if openedRevision == nil { failure = "session_start_failed" }
        }

        guard !Task.isCancelled, pendingAcceptance?.interactionID == suggestion.interactionID else {
            return
        }
        pendingAcceptance = nil
        acceptTask = nil

        if let openedRevision {
            let t = MonotonicClock.now
            policy.record(.accepted, intentClass: suggestion.intentClass, at: t,
                          config: scorer.config)
            var fields = AffordanceLogFields(suggestion: suggestion)
            fields.latencySeconds = latency
            let recorded = writeEvent("accepted", at: t, fields: fields)
            // The synchronous notification may start the provider turn immediately.
            // Publish it only after durable interaction acceptance so log order is
            // always shown → accepted → action_started.
            if recorded {
                IntentAutoRun.shared.arm(suggestion,
                                         sessionRevision: openedRevision,
                                         logSessionID: logSessionID)
                NotificationCenter.default.post(name: .intentAutoRunAction,
                                                object: suggestion.action)
            }
        } else {
            NSSound.beep()
            var fields = AffordanceLogFields(suggestion: suggestion)
            fields.latencySeconds = latency
            fields.reason = failure ?? "unknown_failure"
            _ = writeEvent("accept_failed", at: MonotonicClock.now, fields: fields)
        }
    }

    private func openClipboardSession(suggestion: IntentSuggestion) -> UUID? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        return startSession(suggestion: suggestion, expectedURL: nil) {
            delegate.openSessionFromClipboard()
        }
    }

    private func openFileSession(url: URL, suggestion: IntentSuggestion) -> UUID? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        return startSession(suggestion: suggestion, expectedURL: url) {
            delegate.openSessionWithFiles([url])
        }
    }

    private func startSession(suggestion: IntentSuggestion, expectedURL: URL?,
                              open: () -> Void) -> UUID? {
        let vm = OverlayViewModel.shared
        let before = vm.sessionRevision
        open()

        let stageIsSession: Bool
        switch vm.stage {
        case .chips, .loading, .result: stageIsSession = true
        case .waitingForDrop, .fileResult, .error: stageIsSession = false
        }
        let files = vm.sessionFileURLs
        let expectedPresent = expectedURL.map { expected in
            files.contains { $0.standardizedFileURL == expected.standardizedFileURL }
        } ?? true
        let success = vm.sessionRevision != before && stageIsSession
                   && !files.isEmpty && expectedPresent
        guard success else {
            return nil
        }
        return vm.sessionRevision
    }

    private func dismiss(_ suggestion: IntentSuggestion) {
        let t = MonotonicClock.now
        policy.record(.dismissed, intentClass: suggestion.intentClass, at: t,
                      config: scorer.config)
        var fields = AffordanceLogFields(suggestion: suggestion)
        fields.latencySeconds = max(0, t - shownAt)
        _ = writeEvent("dismissed", at: t, fields: fields)
        hideWindow(recordIgnoreIfPending: false)
        maybePrompt(after: "dismissed", suggestion: suggestion)
    }

    /// `accepted` means only that a real overlay session opened. These three records
    /// make the downstream provider turn separately observable without logging prompt,
    /// source or result content.
    func recordActionStarted(_ suggestion: IntentSuggestion, at t: TimeInterval) {
        let fields = AffordanceLogFields(suggestion: suggestion)
        if writeEvent("action_started", at: t, fields: fields) {
            activeActionStarts[suggestion.interactionID] = (suggestion, t, logSessionID)
        }
    }

    func recordActionCompleted(_ suggestion: IntentSuggestion, latency: TimeInterval) {
        guard takeMatchingActiveAction(suggestion) != nil else { return }
        var fields = AffordanceLogFields(suggestion: suggestion)
        fields.latencySeconds = latency
        let recorded = writeEvent("action_completed", at: MonotonicClock.now, fields: fields)
        if recorded {
            maybePrompt(after: "accepted", suggestion: suggestion,
                        firstQuestion: .resultUseful)
        }
    }

    func recordActionFailed(_ suggestion: IntentSuggestion, latency: TimeInterval) {
        guard takeMatchingActiveAction(suggestion) != nil else { return }
        var fields = AffordanceLogFields(suggestion: suggestion)
        fields.latencySeconds = latency
        // Deliberately categorical: provider error strings may contain request details.
        fields.reason = "provider_or_extraction_error"
        let recorded = writeEvent("action_failed", at: MonotonicClock.now, fields: fields)
        if recorded {
            maybePrompt(after: "accepted", suggestion: suggestion,
                        firstQuestion: .suggestionRelevant)
        }
    }

    func recordActionCancelled(_ suggestion: IntentSuggestion, latency: TimeInterval) {
        guard takeMatchingActiveAction(suggestion) != nil else { return }
        var fields = AffordanceLogFields(suggestion: suggestion)
        fields.latencySeconds = latency
        fields.reason = "session_cancelled_or_replaced"
        _ = writeEvent("action_cancelled", at: MonotonicClock.now, fields: fields)
    }

    private func takeMatchingActiveAction(_ suggestion: IntentSuggestion)
        -> (suggestion: IntentSuggestion, startedAt: TimeInterval, logSessionID: UUID)? {
        guard let active = activeActionStarts[suggestion.interactionID],
              active.logSessionID == logSessionID,
              active.suggestion.action == suggestion.action,
              active.suggestion.channel == suggestion.channel,
              active.suggestion.rank == suggestion.rank else { return nil }
        activeActionStarts[suggestion.interactionID] = nil
        return active
    }

    private func cancelActiveActions(reason: String) {
        let active = activeActionStarts.values
            .filter { $0.logSessionID == logSessionID }
            .sorted { $0.startedAt < $1.startedAt }
        for item in active {
            var fields = AffordanceLogFields(suggestion: item.suggestion)
            fields.latencySeconds = max(0, MonotonicClock.now - item.startedAt)
            fields.reason = "controller_stopped:\(reason)"
            _ = writeEvent("action_cancelled", at: MonotonicClock.now, fields: fields)
        }
        activeActionStarts.removeAll(keepingCapacity: false)
    }

    /// Writer failure cannot append cancellations to the failed stream, but stale
    /// provider completions still must not cross into a later retry session.
    private func discardActiveActions() {
        activeActionStarts.removeAll(keepingCapacity: false)
    }

    private func fadeExpired() {
        guard let suggestion = current else { return }
        let t = MonotonicClock.now
        policy.record(.ignored, intentClass: suggestion.intentClass, at: t,
                      config: scorer.config)
        var fields = AffordanceLogFields(suggestion: suggestion)
        fields.latencySeconds = max(0, t - shownAt)
        _ = writeEvent("ignored", at: t, fields: fields)
        hideWindow(recordIgnoreIfPending: false)
    }

    // MARK: Window plumbing

    private func showWhisper(_ suggestion: IntentSuggestion) {
        show(content: .suggestion(suggestion), size: CGSize(width: 460, height: 44))
        acceptHotkey.register(keyCode: UInt32(kVK_Return),
                              modifiers: UInt32(optionKey)) { [weak self] in
            guard let self, let current = self.current else { return }
            self.accept(current)
        }
        armFade()
    }

    private func show(content: WhisperContent, size: CGSize) {
        let scale = UIScale.current.multiplier
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
        let win = window ?? WhisperWindow(contentSize: scaledSize)
        window = win

        let root: AnyView
        switch content {
        case .suggestion(let suggestion):
            root = AnyView(WhisperSuggestionView(
                suggestion: suggestion,
                onAccept: { [weak self] in self?.accept(suggestion) },
                onDismiss: { [weak self] in self?.dismiss(suggestion) },
                onHover: { [weak self] hovering in
                    hovering ? self?.fadeTimer?.invalidate() : self?.armFade()
                }).environment(\.uiScale, scale))
        case .ticker(let rows):
            root = AnyView(WhisperTickerView(
                rows: rows,
                onAccept: { [weak self] in self?.accept($0) },
                onClose: { [weak self] in self?.closeTicker(reason: "user_closed") })
                .environment(\.uiScale, scale))
        case .prompt(let prompt):
            root = AnyView(WhisperPromptView(
                prompt: prompt,
                onAnswerYesNo: { [weak self] in self?.advancePrompt(answer: $0) },
                onAnswerContext: { [weak self] in self?.finishPrompt(context: $0) },
                onSkip: { [weak self] in self?.skipPrompt() })
                .environment(\.uiScale, scale))
        case .hint:
            root = AnyView(WhisperHintView(
                onClose: { [weak self] in self?.hideWindow(recordIgnoreIfPending: false) })
                .environment(\.uiScale, scale))
        }

        win.contentView = NSHostingView(rootView: root)
        win.setContentSize(scaledSize)
        win.place(size: scaledSize)
        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            win.animator().alphaValue = 1
        }
    }

    private func hideWindow(recordIgnoreIfPending: Bool) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        acceptHotkey.unregister()
        if recordIgnoreIfPending, let suggestion = current {
            let t = MonotonicClock.now
            policy.record(.ignored, intentClass: suggestion.intentClass, at: t,
                          config: scorer.config)
            var fields = AffordanceLogFields(suggestion: suggestion)
            fields.latencySeconds = max(0, t - shownAt)
            fields.reason = "displaced"
            _ = writeEvent("ignored", at: t, fields: fields)
        }
        current = nil
        tickerVisible = false
        tickerInteractionID = nil
        tickerRows = []
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            win.animator().alphaValue = 0
        }) {
            win.orderOut(nil)
        }
    }

    private func armFade() {
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: fadeSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeExpired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func armTickerTimeout() {
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: tickerTimeoutSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeTicker(reason: "timeout") }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: Summon hint

    func showSummonHint() {
        guard isStarted, logHealth.isHealthy else { return }
        cancelPrompt(reason: "displaced_by_hint", hideSurface: true)
        var fields = AffordanceLogFields()
        fields.interactionID = UUID()
        _ = writeEvent("summon_hint_shown", at: MonotonicClock.now, fields: fields)
        show(content: .hint, size: CGSize(width: 460, height: 82))
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: 25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideWindow(recordIgnoreIfPending: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: Experience sampling

    private var pendingPrompt: InSituPrompt?
    private var activePrompt: InSituPrompt?
    private var promptWorkItem: DispatchWorkItem?
    private let maxPromptsPerDay = 5
    private let minPromptGap: TimeInterval = 900
    private let quotaParticipantKey = "intentPromptQuota.participant"
    private let quotaDayKey = "intentPromptQuota.day"
    private let quotaCountKey = "intentPromptQuota.count"
    private let quotaLastKey = "intentPromptQuota.last"

    /// Setup archives the previous data cohort, so the experience-sampling budget is
    /// part of that same run boundary. Needed when a researcher deliberately reuses a
    /// pilot install, participant ID, and calendar day.
    func resetPromptQuotaForNewStudy() {
        let defaults = UserDefaults.standard
        [quotaParticipantKey, quotaDayKey, quotaCountKey, quotaLastKey].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    private func maybePrompt(after outcome: String, suggestion: IntentSuggestion,
                             firstQuestion: InSituPrompt.FirstQuestion = .suggestionRelevant) {
        guard StudyMode.isActive, canPresentPrompt(), promptQuotaAllows(at: MonotonicClock.now) else {
            return
        }
        cancelPrompt(reason: "displaced_by_new_prompt", hideSurface: true)
        let prompt = InSituPrompt(interactionID: suggestion.interactionID,
                                  channel: suggestion.channel,
                                  rank: suggestion.rank,
                                  intentClass: suggestion.intentClass,
                                  action: suggestion.action.rawValue,
                                  outcome: outcome,
                                  firstQuestion: firstQuestion)
        pendingPrompt = prompt
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.presentPendingPrompt() }
        }
        promptWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    private func presentPendingPrompt() {
        guard let prompt = pendingPrompt else { return }
        guard canPresentPrompt() else {
            cancelPrompt(reason: "inactive_before_display", hideSurface: false)
            return
        }
        guard promptQuotaAllows(at: MonotonicClock.now) else {
            cancelPrompt(reason: "quota_changed_before_display", hideSurface: false)
            return
        }
        commitPromptQuota(at: MonotonicClock.now)
        promptWorkItem = nil
        pendingPrompt = nil
        activePrompt = prompt
        show(content: .prompt(prompt), size: CGSize(width: 380, height: 86))
        armPromptTimeout()
    }

    private func canPresentPrompt() -> Bool {
        isStarted && logHealth.isHealthy && StudyMode.isActive
            && IntentEngine.shared.isRunning && !IntentEngine.shared.isPaused
    }

    private func promptQuotaAllows(at _: TimeInterval) -> Bool {
        let defaults = UserDefaults.standard
        let participant = StudyMode.participantID ?? ""
        let day = TraceRecorder.dayKey(for: Date())
        guard defaults.string(forKey: quotaParticipantKey) == participant,
              defaults.string(forKey: quotaDayKey) == day else { return true }
        return defaults.integer(forKey: quotaCountKey) < maxPromptsPerDay
            && MonotonicClock.wallNow - defaults.double(forKey: quotaLastKey) >= minPromptGap
    }

    private func commitPromptQuota(at _: TimeInterval) {
        let defaults = UserDefaults.standard
        let participant = StudyMode.participantID ?? ""
        let day = TraceRecorder.dayKey(for: Date())
        let sameBucket = defaults.string(forKey: quotaParticipantKey) == participant
                      && defaults.string(forKey: quotaDayKey) == day
        defaults.set(participant, forKey: quotaParticipantKey)
        defaults.set(day, forKey: quotaDayKey)
        defaults.set((sameBucket ? defaults.integer(forKey: quotaCountKey) : 0) + 1,
                     forKey: quotaCountKey)
        // Quota survives process restart and reboot, so its persisted anchor must be
        // wall time. Uptime is only comparable inside one boot/process session.
        defaults.set(MonotonicClock.wallNow, forKey: quotaLastKey)
    }

    private func armPromptTimeout() {
        fadeTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.skipPrompt(reason: "timeout") }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func advancePrompt(answer: Bool) {
        guard var prompt = activePrompt else { return }
        switch prompt.stage {
        case .assessment:
            prompt.firstAnswer = answer
            prompt.stage = .intrusive
        case .intrusive:
            prompt.intrusive = answer
            prompt.stage = .context
        case .context:
            return
        }
        activePrompt = prompt
        let size = prompt.stage == .context ? CGSize(width: 380, height: 200)
                                             : CGSize(width: 380, height: 86)
        show(content: .prompt(prompt), size: size)
        armPromptTimeout()
    }

    private func finishPrompt(context: String) {
        guard let prompt = activePrompt else { return }
        logPrompt(prompt, context: context, skipped: nil)
        activePrompt = nil
        hideWindow(recordIgnoreIfPending: false)
    }

    private func skipPrompt(reason: String = "skipped") {
        guard let prompt = activePrompt else { return }
        logPrompt(prompt, context: nil, skipped: reason)
        activePrompt = nil
        hideWindow(recordIgnoreIfPending: false)
    }

    private func cancelPrompt(reason: String, hideSurface: Bool) {
        guard let prompt = activePrompt ?? pendingPrompt else { return }
        promptWorkItem?.cancel()
        promptWorkItem = nil
        logPrompt(prompt, context: nil, skipped: reason)
        let wasVisible = activePrompt != nil
        activePrompt = nil
        pendingPrompt = nil
        if hideSurface && wasVisible { hideWindow(recordIgnoreIfPending: false) }
    }

    private func logPrompt(_ prompt: InSituPrompt, context: String?, skipped: String?) {
        var fields = AffordanceLogFields()
        fields.interactionID = prompt.interactionID
        fields.channel = prompt.channel
        fields.rank = prompt.rank
        fields.intentClass = prompt.intentClass
        fields.action = prompt.action
        fields.promptOutcome = prompt.outcome
        fields.promptQuestion = prompt.firstQuestion.rawValue
        switch prompt.firstQuestion {
        case .suggestionRelevant: fields.promptRelevant = prompt.firstAnswer
        case .resultUseful: fields.promptUseful = prompt.firstAnswer
        }
        fields.promptIntrusive = prompt.intrusive
        fields.promptContext = context
        fields.promptSkipped = skipped
        switch prompt.stage {
        case .assessment: fields.promptAnsweredStage = "none"
        case .intrusive: fields.promptAnsweredStage = "assessment"
        case .context: fields.promptAnsweredStage = "assessment+intrusive"
        }
        _ = writeEvent("prompt", at: MonotonicClock.now, fields: fields)
    }

    // MARK: Typed, fail-closed affordance log

    private func openLog() throws {
        let directory = try TraceRecorder.ensureTracesDirectory()
        let url = directory.appendingPathComponent("affordance-log.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw AffordanceLogError.createFailed(url)
            }
        }
        // Validate any older journal before touching source bytes. Recover only an
        // interrupted tail record. A crash can happen after the JSON
        // bytes but before the newline; appending directly would concatenate two JSON
        // objects and poison the whole multi-day log. Interior corruption remains a
        // visible export failure and is never rewritten here.
        _ = try Self.readRecoveryJournal(in: directory)
        _ = try Self.recoverIncompleteTailIfNeeded(url, journalDirectory: directory)
        pendingTailRecoveries = try Self.readRecoveryJournal(in: directory)
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        logSessionID = UUID()
        logHandle = handle
        lastLogSyncUptime = MonotonicClock.uptimeNow
        logHealth = AffordanceLogHealth(state: .healthy, url: url, error: nil)
        armLogSyncTimer()
    }

    private static func recoverIncompleteTailIfNeeded(
        _ url: URL, journalDirectory: URL
    ) throws -> AffordanceTailRecovery? {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return nil }
        try handle.seek(toOffset: size - 1)
        guard try handle.read(upToCount: 1) != Data([0x0A]) else { return nil }

        let chunkSize: UInt64 = 64 * 1_024
        var cursor = size
        var lastLineStart: UInt64 = 0
        search: while cursor > 0 {
            let start = cursor > chunkSize ? cursor - chunkSize : 0
            try handle.seek(toOffset: start)
            let chunk = try handle.read(upToCount: Int(cursor - start)) ?? Data()
            if let index = chunk.lastIndex(of: 0x0A) {
                lastLineStart = start + UInt64(chunk.distance(from: chunk.startIndex, to: index)) + 1
                break search
            }
            cursor = start
        }

        try handle.seek(toOffset: lastLineStart)
        let tail = try handle.readToEnd() ?? Data()
        let recovery: AffordanceTailRecovery
        if (try? JSONSerialization.jsonObject(with: tail)) is [String: Any] {
            recovery = AffordanceTailRecovery(
                v: 1, action: "completed_valid_tail_missing_newline",
                affectedBytes: size - lastLineStart,
                recoveredWallTime: MonotonicClock.wallNow)
            try appendRecoveryJournal(recovery, in: journalDirectory)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
            try handle.synchronize()
            return recovery
        }

        recovery = AffordanceTailRecovery(
            v: 1, action: "discarded_incomplete_tail",
            affectedBytes: size - lastLineStart,
            recoveredWallTime: MonotonicClock.wallNow)
        try appendRecoveryJournal(recovery, in: journalDirectory)
        try handle.truncate(atOffset: lastLineStart)
        try handle.synchronize()
        return recovery
    }

    private static func recoveryJournalURL(in directory: URL) -> URL {
        directory.appendingPathComponent("affordance-recovery-journal.jsonl")
    }

    private static func appendRecoveryJournal(_ recovery: AffordanceTailRecovery,
                                              in directory: URL) throws {
        let url = recoveryJournalURL(in: directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw AffordanceLogError.createFailed(url)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(recovery) + Data("\n".utf8))
        try handle.synchronize()
    }

    private static func readRecoveryJournal(in directory: URL) throws
        -> [AffordanceTailRecovery] {
        let url = recoveryJournalURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.last == 0x0A, let text = String(data: data, encoding: .utf8) else {
            throw AffordanceLogError.unhealthy("invalid recovery journal at \(url.path)")
        }
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map {
            let row = try decoder.decode(AffordanceTailRecovery.self, from: Data($0.utf8))
            guard row.v == 1,
                  ["completed_valid_tail_missing_newline", "discarded_incomplete_tail"]
                    .contains(row.action),
                  row.affectedBytes > 0,
                  row.recoveredWallTime.isFinite, row.recoveredWallTime > 0 else {
                throw AffordanceLogError.unhealthy("invalid recovery journal at \(url.path)")
            }
            return row
        }
    }

    private static func clearRecoveryJournal(in directory: URL) throws {
        let url = recoveryJournalURL(in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    private func writeEvent(_ event: String, at t: TimeInterval,
                            fields: AffordanceLogFields) -> Bool {
        guard let handle = logHandle, logHealth.isHealthy else { return false }
        let snapshot = modelSnapshot(at: t)
        let stamp = StudyMode.stampFields
        let writeStamp = MonotonicClock.snapshot()
        let record = AffordanceEventRecord(
            schemaVersion: 4,
            recordType: event == "session_boundary" ? "session_boundary" : "affordance_event",
            logSessionID: logSessionID.uuidString, event: event,
            t: t, wall: writeStamp.wallTime, loggedUptime: writeStamp.uptime,
            boot: stamp["boot"] ?? MonotonicClock.sessionID,
            sessionID: MonotonicClock.sessionID,
            processID: MonotonicClock.processID,
            participant: stamp["participant"], study: stamp["study"] == "true",
            consentVersion: stamp["consent_version"].flatMap(Int.init),
            consentAcceptedAt: stamp["consent_accepted_at"].flatMap(Double.init),
            interactionID: fields.interactionID?.uuidString,
            channel: fields.channel?.rawValue, rank: fields.rank,
            intentClass: fields.intentClass?.rawValue, probability: fields.probability,
            action: fields.action, targetKind: fields.targetKind,
            targetItemCount: fields.targetItemCount,
            latencySeconds: fields.latencySeconds, reason: fields.reason,
            passiveWasSilent: fields.passiveWasSilent,
            actionable: fields.actionable, actionableCount: fields.actionableCount,
            rowCount: fields.rowCount, promptOutcome: fields.promptOutcome,
            promptQuestion: fields.promptQuestion,
            promptRelevant: fields.promptRelevant,
            promptUseful: fields.promptUseful,
            promptIntrusive: fields.promptIntrusive,
            promptContext: fields.promptContext,
            promptAnsweredStage: fields.promptAnsweredStage,
            promptSkipped: fields.promptSkipped,
            recoveryAffectedBytes: fields.recoveryAffectedBytes,
            exposureThreshold: scorer.config.exposureThreshold,
            classScores: snapshot.scores, evidence: snapshot.evidence)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record) + Data("\n".utf8)
            try handle.write(contentsOf: data)
            if writeStamp.uptime - lastLogSyncUptime >= Self.logSyncInterval {
                try handle.synchronize()
                lastLogSyncUptime = writeStamp.uptime
            }
            return true
        } catch {
            failLogging(error)
            return false
        }
    }

    /// Complete, lossless scorer state for offline replay: no contribution threshold,
    /// no decimal formatting, and every class is present even at its base prior.
    private func modelSnapshot(at t: TimeInterval)
        -> (scores: [AffordanceClassScoreRecord], evidence: [AffordanceEvidenceRecord]) {
        var evidenceRecords: [AffordanceEvidenceRecord] = []
        for observation in scorer.evidence {
            let intentClass = observation.feature.intentClass
            let age = max(0, t - observation.t)
            let tau = scorer.config.tau(for: observation.feature)
            let decay = exp(-age / tau)
            let weight = scorer.config.weight(for: observation.feature)
            evidenceRecords.append(AffordanceEvidenceRecord(
                intentClass: intentClass.rawValue,
                featureID: observation.feature.rawValue,
                observedAt: observation.t,
                rawStrength: observation.strength,
                ageSeconds: age,
                tauSeconds: tau,
                decay: decay,
                weight: weight,
                weightedContribution: weight * observation.strength * decay))
        }
        evidenceRecords.sort {
            if $0.intentClass == $1.intentClass { return $0.observedAt < $1.observedAt }
            return $0.intentClass < $1.intentClass
        }

        // These are the exact probabilities used by policy at runtime. The complete
        // unthresholded evidence vector above remains available for alternate offline
        // re-scoring without making the recorded decision state internally disagree.
        let scores = scorer.scores(at: t).map { breakdown in
            AffordanceClassScoreRecord(intentClass: breakdown.intentClass.rawValue,
                                       logOdds: breakdown.logOdds,
                                       probability: breakdown.probability)
        }
        return (scores, evidenceRecords)
    }

    /// A log failure is also an execution boundary. A materialisation task may be
    /// suspended inside AX/document work; cancellation plus clearing its identity
    /// guarantees that its post-await guard cannot open a stale session after retry.
    private func cancelPendingAcceptance() {
        acceptTask?.cancel()
        acceptTask = nil
        pendingAcceptance = nil
    }

    /// Failure cannot record a prompt outcome, but it must prevent an old delayed
    /// work item or hidden active prompt from leaking into the next log session.
    private func discardPromptState() {
        promptWorkItem?.cancel()
        promptWorkItem = nil
        pendingPrompt = nil
        activePrompt = nil
    }

    private func failLogging(_ error: Error) {
        IntentAutoRun.shared.clear(logSessionID: logSessionID)
        cancelPendingAcceptance()
        discardPromptState()
        discardActiveActions()
        var message = error.localizedDescription
        if let handle = logHandle {
            do {
                try handle.close()
            } catch {
                message += " · close failed: \(error.localizedDescription)"
            }
            logHandle = nil
        }
        lastLogSyncUptime = 0
        logSyncTimer?.invalidate()
        logSyncTimer = nil
        logHealth = AffordanceLogHealth(state: .failed, url: logHealth.url, error: message)
        isStarted = false
        summonHotkey.unregister()
        acceptHotkey.unregister()
        tickerTask?.cancel()
        tickerTask = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        current = nil
        tickerVisible = false
        tickerRows = []
        tickerInteractionID = nil
        window?.orderOut(nil)
        extractor.clearResolverCandidates()
        IntentContentVault.shared.clear()
        NotificationCenter.default.post(name: .intentAffordanceLogFailed,
                                        object: self,
                                        userInfo: ["error": message])
    }

    private func armLogSyncTimer() {
        logSyncTimer?.invalidate()
        let timer = Timer(timeInterval: Self.logSyncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeLogPeriodically() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        logSyncTimer = timer
    }

    private func synchronizeLogPeriodically() {
        guard let handle = logHandle, logHealth.isHealthy else { return }
        do {
            try handle.synchronize()
            lastLogSyncUptime = MonotonicClock.uptimeNow
        } catch {
            failLogging(error)
        }
    }

#if THESIS_STUDY_BUILD
    /// Isolated crash-tail transaction fixture; it never touches participant data.
    static func tailRecoveryCheckForTesting() -> Bool {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(
            "dragaway-affordance-tail-check-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: directory) }
            let log = directory.appendingPathComponent("affordance-log.jsonl")
            try Data("{\"valid\":true}".utf8).write(to: log)
            let first = try recoverIncompleteTailIfNeeded(log, journalDirectory: directory)

            let handle = try FileHandle(forWritingTo: log)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"partial\":".utf8))
            try handle.close()
            let second = try recoverIncompleteTailIfNeeded(log, journalDirectory: directory)
            let journal = try readRecoveryJournal(in: directory)
            let final = try Data(contentsOf: log)
            return first?.action == "completed_valid_tail_missing_newline"
                && second?.action == "discarded_incomplete_tail"
                && journal.count == 2
                && final == Data("{\"valid\":true}\n".utf8)
        } catch {
            return false
        }
    }
#endif
}

// MARK: - Quiet contexts

enum QuietContext {
    static func isQuiet() -> Bool {
        guard let screen = NSScreen.main,
              let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }

        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == frontPID,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else { continue }
            if bounds.width >= screen.frame.width, bounds.height >= screen.frame.height {
                return true
            }
        }
        return false
    }
}
