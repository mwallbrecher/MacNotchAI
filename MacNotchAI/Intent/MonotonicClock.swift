import Foundation

// THESIS (study instrumentation) — one observation contains both clocks needed to
// interpret a long-running trace honestly.
//
// `wallTime` answers "when did this happen?" and advances across sleep, but may jump
// when NTP or the participant changes the clock. `uptime` answers "how much active
// runtime elapsed in this launch?" and never jumps, but pauses while the Mac sleeps.
// Neither clock is silently rewritten. A changed wall-minus-uptime offset is emitted
// as an explicit discontinuity and sleep/wake remains an explicit lifecycle marker.
enum MonotonicClock {

    struct Stamp: Codable, Equatable {
        let wallTime: TimeInterval
        let uptime: TimeInterval
        let sessionID: String
        let processID: Int32
        let discontinuity: Discontinuity?
    }

    struct Discontinuity: Codable, Equatable {
        enum Kind: String, Codable {
            case wallClockStep = "wall_clock_step"
            case uptimeReset = "uptime_reset"
        }

        let kind: Kind
        let detectedWallTime: TimeInterval
        let previousWallTime: TimeInterval
        let previousUptime: TimeInterval
        let currentUptime: TimeInterval
        /// Difference between observed wall elapsed time and uptime elapsed time.
        /// Positive values include sleep or a forward clock step; negative values are
        /// a backward clock step. Sleep/wake markers disambiguate normal sleep gaps.
        let wallMinusUptimeDelta: TimeInterval
    }

    /// One launch/process session. It changes after app restart even without a reboot.
    static let sessionID = UUID().uuidString
    static let processID = ProcessInfo.processInfo.processIdentifier

    private static let lock = NSLock()
    private static var lastWall: TimeInterval?
    private static var lastUptime: TimeInterval?
    private static var steps: [Discontinuity] = []
    private static let discontinuityThreshold: TimeInterval = 1

    /// Captures both clocks atomically enough for one signal and records—not clamps—
    /// any meaningful divergence. This is the source used by `SignalEvent.init`.
    static func stamp() -> Stamp {
        let wall = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime

        lock.lock()
        defer { lock.unlock() }

        var discontinuity: Discontinuity?
        if let previousWall = lastWall, let previousUptime = lastUptime {
            if uptime < previousUptime {
                discontinuity = Discontinuity(
                    kind: .uptimeReset,
                    detectedWallTime: wall,
                    previousWallTime: previousWall,
                    previousUptime: previousUptime,
                    currentUptime: uptime,
                    wallMinusUptimeDelta: (wall - previousWall) - (uptime - previousUptime))
            } else {
                let drift = (wall - previousWall) - (uptime - previousUptime)
                if abs(drift) > discontinuityThreshold {
                    discontinuity = Discontinuity(
                        kind: .wallClockStep,
                        detectedWallTime: wall,
                        previousWallTime: previousWall,
                        previousUptime: previousUptime,
                        currentUptime: uptime,
                        wallMinusUptimeDelta: drift)
                }
            }
        }

        if let discontinuity { steps.append(discontinuity) }
        lastWall = wall
        lastUptime = uptime
        return Stamp(wallTime: wall, uptime: uptime, sessionID: sessionID,
                     processID: processID, discontinuity: discontinuity)
    }

    /// Time base for ordering, windows, durations, and score decay during one process
    /// session. Reading it has no bookkeeping side effect: `SignalEvent.init` owns the
    /// single dual-clock stamp so a discontinuity cannot be consumed before recording.
    static var now: TimeInterval { uptimeNow }

    static var wallNow: TimeInterval { Date().timeIntervalSince1970 }
    static var uptimeNow: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Non-mutating pair for secondary logs. Only `SignalEvent.live` may consume and
    /// persist clock discontinuities; affordance logging must not steal the first
    /// post-clock-change marker from the trace stream.
    static func snapshot() -> (wallTime: TimeInterval, uptime: TimeInterval) {
        (Date().timeIntervalSince1970, ProcessInfo.processInfo.systemUptime)
    }

    static var discontinuities: [Discontinuity] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }

    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        lastWall = nil
        lastUptime = nil
        steps = []
    }
}
