import Foundation

// THESIS (L5 handoff latch) — robust delivery of "run this action" from a whisper
// accept into the freshly opened session.
//
// Why a latch and not just a notification: the overlay window/view is immortal
// (drag-snapshot design), so `.onAppear` does NOT fire when a parked window is
// reused, and a fire-and-forget NotificationCenter.post is lost if the chips view
// isn't listening yet. The latch survives that race: after a session is verified and
// `accepted` is durable, the controller arms its exact revision before posting the
// notification. The chips view consumes it once only from that same revision. A
// monotonic expiry and lifecycle clears are secondary bounds; identity is the primary
// defence against an old accept running on a later file session.
@MainActor
final class IntentAutoRun {
    static let shared = IntentAutoRun()

    private struct Pending {
        let suggestion: IntentSuggestion
        let sessionRevision: UUID
        let logSessionID: UUID
        let expiresAt: TimeInterval
    }

    private let now: () -> TimeInterval
    private var pending: Pending?

    private init(now: @escaping () -> TimeInterval = {
        ProcessInfo.processInfo.systemUptime
    }) {
        self.now = now
    }

    func arm(_ suggestion: IntentSuggestion, sessionRevision: UUID,
             logSessionID: UUID, ttl: TimeInterval = 4) {
        guard ttl > 0 else {
            pending = nil
            return
        }
        pending = Pending(suggestion: suggestion,
                          sessionRevision: sessionRevision,
                          logSessionID: logSessionID,
                          expiresAt: now() + ttl)
    }

    /// Returns the exact accepted suggestion once only when the rendering overlay is
    /// still the session opened by that accept. Every attempted take consumes the
    /// latch, including a revision mismatch, because revisions never become current
    /// again and retaining a known-stale action only creates another delivery race.
    func take(expectedRevision: UUID) -> IntentSuggestion? {
        guard let pending else { return nil }
        self.pending = nil
        guard pending.sessionRevision == expectedRevision,
              now() < pending.expiresAt else { return nil }
        return pending.suggestion
    }

    /// A controller lifecycle boundary clears only its own pending delivery. The log
    /// identity prevents a delayed old stop from erasing a newer session's latch.
    func clear(logSessionID: UUID) {
        guard pending?.logSessionID == logSessionID else { return }
        pending = nil
    }

    func clear() {
        pending = nil
    }

#if THESIS_STUDY_BUILD
    /// Pure deterministic fixture: isolated clock/state, no singleton, files, UI, or
    /// participant data. It proves that a wrong revision is rejected and consumed,
    /// and that log-scoped plus unconditional lifecycle clears behave exactly.
    static func revisionBindingCheckForTesting()
        -> (mismatchRejected: Bool, mismatchConsumed: Bool,
            wrongLogPreserved: Bool, exactLogCleared: Bool,
            unconditionalCleared: Bool) {
        var clock: TimeInterval = 100
        let latch = IntentAutoRun(now: { clock })
        let revision = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let otherRevision = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let logSession = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let otherLogSession = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let interaction = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let suggestion = IntentSuggestion(
            interactionID: interaction, channel: .passive, rank: 1,
            intentClass: .translation, action: .translateEnglish,
            phrase: "Golden auto-run", target: .pasteboard(hash: "golden"),
            probability: 0.9)

        latch.arm(suggestion, sessionRevision: revision,
                  logSessionID: logSession, ttl: 10)
        let mismatchRejected = latch.take(expectedRevision: otherRevision) == nil
        let mismatchConsumed = latch.take(expectedRevision: revision) == nil

        latch.arm(suggestion, sessionRevision: revision,
                  logSessionID: logSession, ttl: 10)
        latch.clear(logSessionID: otherLogSession)
        let wrongLogPreserved = latch.take(expectedRevision: revision)?.interactionID == interaction

        latch.arm(suggestion, sessionRevision: revision,
                  logSessionID: logSession, ttl: 10)
        latch.clear(logSessionID: logSession)
        let exactLogCleared = latch.take(expectedRevision: revision) == nil

        latch.arm(suggestion, sessionRevision: revision,
                  logSessionID: logSession, ttl: 10)
        clock += 1
        latch.clear()
        let unconditionalCleared = latch.take(expectedRevision: revision) == nil

        return (mismatchRejected, mismatchConsumed, wrongLogPreserved,
                exactLogCleared, unconditionalCleared)
    }
#endif
}
