import AppKit

// THESIS (L1 sensor + energy governor) — input activity, without claiming that
// "hands off" necessarily means "away".
//
// Input inactivity is observable; absence is not. Someone may spend several minutes
// reading a PDF without touching the keyboard or trackpad. The monitor therefore
// records two explicit, differently named boundaries:
//
//   · inactive             after 60 s — ambiguous quiet work, sensors keep running;
//   · extended_inactivity  after 5 min — still ambiguous, but long enough to gate
//                          expensive periodic polling for energy.
//
// Analysis can use the markers without silently treating quiet reading as time away
// from the desk. A later `active` event closes either span and carries its duration.
// Sleep is a different, observable condition and is recorded by IntentEngine.
//
// `CGEventSource.secondsSinceLastEventType` is permission-free. It is also the
// keyboard-only wake fallback: global NSEvent key monitors are not dependable without
// Accessibility/Input Monitoring permission. While polling is gated, a coalescible
// 1 Hz timer checks the CGEventSource state, so ordinary typing always wakes capture.
final class ActivityMonitor {

    private enum Phase {
        case active
        case inactive(since: TimeInterval)
        case extendedInactivity(since: TimeInterval)
    }

    private let inactivityThreshold: TimeInterval = 60
    private let extendedInactivityThreshold: TimeInterval = 5 * 60
    private let activeCheckInterval: TimeInterval = 15
    private let gatedWakeCheckInterval: TimeInterval = 1

    private weak var bus: SignalBus?
    private var checkTimer: Timer?
    /// Discrete pointer events make return feel immediate without subscribing to the
    /// extremely chatty `.mouseMoved` stream. Keyboard-only return is covered by the
    /// permission-free CGEventSource timer above.
    private var pointerMonitor: Any?
    private var phase: Phase = .active
    private var isSuspended = true
    /// Prevents CGEventSource's pre-launch/pre-resume history from being attributed to
    /// this capture segment. Uptime is suitable here because sleep always creates a
    /// fresh segment through IntentEngine's explicit sleep/wake lifecycle.
    private var segmentStartedAtUptime = ProcessInfo.processInfo.systemUptime

    /// `true` asks IntentEngine to gate periodic sensors; `false` re-arms them.
    /// Entering is called BEFORE the marker is published, so sensors can close their
    /// pre-gap state first. Leaving is called AFTER the `active` marker, so no resumed
    /// sensor can overtake the boundary in the trace.
    var onGatingChange: ((_ shouldGate: Bool) -> Void)?

    func start(bus: SignalBus) {
        self.bus = bus
        resume()
    }

    func stop() {
        suspend()
        bus = nil
        onGatingChange = nil
    }

    /// Used for manual pause and system sleep. It emits nothing: IntentEngine owns the
    /// corresponding explicit gap marker and must be the only publisher at that point.
    func suspend() {
        isSuspended = true
        checkTimer?.invalidate()
        checkTimer = nil
        if let monitor = pointerMonitor { NSEvent.removeMonitor(monitor) }
        pointerMonitor = nil
        phase = .active
    }

    /// Re-arm after pause/wake. An immediate state check handles a machine that was
    /// already untouched before launch without waiting for the first 15-second tick.
    func resume() {
        guard isSuspended, bus != nil else { return }
        isSuspended = false
        phase = .active
        segmentStartedAtUptime = ProcessInfo.processInfo.systemUptime
        armPointerMonitor()
        // A new capture segment (launch, manual resume, wake) begins at an explicit
        // marker owned by IntentEngine. Do not immediately backdate another inactivity
        // span across that boundary using CGEventSource's pre-segment state.
        scheduleCheck(interval: activeCheckInterval)
    }

    // MARK: Wiring

    private func armPointerMonitor() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] _ in
            self?.noteObservedInput()
        }
    }

    private func scheduleCheck(interval: TimeInterval) {
        guard !isSuspended else { return }
        checkTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    // MARK: State transitions

    /// Seconds since any human input (key, mouse, trackpad, tablet).
    private var secondsSinceInput: CFTimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        let value = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: anyInput)
        return value.isFinite && value >= 0 ? value : 0
    }

    private func checkActivity() {
        guard !isSuspended else { return }
        let segmentAge = max(0, ProcessInfo.processInfo.systemUptime - segmentStartedAtUptime)
        let quietFor = min(secondsSinceInput, segmentAge)

        switch phase {
        case .active:
            guard quietFor >= inactivityThreshold else { return }
            enterInactive(quietFor: quietFor)
            if quietFor >= extendedInactivityThreshold {
                enterExtendedInactivity(quietFor: quietFor)
            }

        case .inactive:
            if quietFor < inactivityThreshold {
                becomeActive(detectionLag: quietFor)
            } else if quietFor >= extendedInactivityThreshold {
                enterExtendedInactivity(quietFor: quietFor)
            }

        case .extendedInactivity:
            if quietFor < inactivityThreshold { becomeActive(detectionLag: quietFor) }
        }
    }

    private func noteObservedInput() {
        guard !isSuspended else { return }
        switch phase {
        case .active:
            return
        case .inactive, .extendedInactivity:
            becomeActive(detectionLag: 0)
        }
    }

    private func enterInactive(quietFor: TimeInterval) {
        let event = SignalEvent.live(kind: .activity,
                                     activity: ActivityPayload(state: "inactive",
                                                               seconds: quietFor))
        phase = .inactive(since: event.t - quietFor)
        bus?.publish(event)
    }

    private func enterExtendedInactivity(quietFor: TimeInterval) {
        let now = MonotonicClock.now
        let since: TimeInterval
        if case .inactive(let inactiveSince) = phase {
            since = inactiveSince
        } else {
            since = now - quietFor
        }

        // Close/gate sensors before the marker so any final dwell/scroll observation
        // belongs unambiguously to the active side of the boundary.
        onGatingChange?(true)
        let event = SignalEvent.live(kind: .activity,
                                     activity: ActivityPayload(state: "extended_inactivity",
                                                               seconds: quietFor))
        phase = .extendedInactivity(since: since)
        bus?.publish(event)
        scheduleCheck(interval: gatedWakeCheckInterval)
    }

    private func becomeActive(detectionLag: TimeInterval) {
        guard !isSuspended else { return }
        let since: TimeInterval
        switch phase {
        case .active:
            return
        case .inactive(let value), .extendedInactivity(let value):
            since = value
        }

        let wasGated: Bool
        if case .extendedInactivity = phase { wasGated = true } else { wasGated = false }
        phase = .active
        let event = SignalEvent.live(kind: .activity,
                                     activity: ActivityPayload(
                                        state: "active",
                                        seconds: max(0, MonotonicClock.now - detectionLag - since)))
        bus?.publish(event)
        scheduleCheck(interval: activeCheckInterval)
        if wasGated { onGatingChange?(false) }
    }
}
