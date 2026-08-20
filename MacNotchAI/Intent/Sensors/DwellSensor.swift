import AppKit

// THESIS (L1 sensor) — scroll bursts + mouse-stationary dwell, fully ungated.
//
// Scroll: a global `.scrollWheel` NSEvent monitor (pointer events don't require
// Accessibility — proven pattern from DragMonitor's mouse monitors). Raw scroll
// events are far too chatty for the bus, so they aggregate into BURSTS (gap > 0.8 s
// closes a burst). Direction changes per burst feed the M2 `re_reading` detector.
// If some system configuration doesn't deliver global scroll events, traces will
// show it immediately; the AX-based fallback lands with M2.
//
// Dwell: 2 Hz polling of `NSEvent.mouseLocation` (the DragMonitor fallback trick —
// no permission, no event tap). Stationary ≥ 10 s emits a dwell event when movement
// resumes; an OS key-idle counter suppresses intervals that contained typing.
final class DwellSensor: IntentSensor {

    let name = "dwell"

    private weak var bus: SignalBus?
    private var scrollMonitor: Any?
    private var housekeeping: Timer?
    private var isSuspended = true

    // Scroll-burst accumulation
    private var burstOpen = false
    private var burstStart: TimeInterval = 0
    private var burstLast: TimeInterval = 0
    private var burstNet: Double = 0
    private var burstAbs: Double = 0
    private var burstFlips = 0
    private var burstLastSign = 0
    private var burstApp: String?

    // Mouse dwell
    private var lastMouse = NSEvent.mouseLocation
    private var stationarySince: TimeInterval?
    private var stationaryApp: String?

    private let burstGap: TimeInterval = 0.8
    private let dwellMinimum: TimeInterval = 10
    private let jitterDeadband: CGFloat = 4      // pt of mouse jitter that still counts as "still"
    private let scrollDeadband: Double = 1       // |ΔY| below this doesn't flip direction

    func start(bus: SignalBus) {
        self.bus = bus
        resume()
    }

    func stop() {
        suspend()
        bus = nil
    }

    /// Close the observable portion immediately before a pause/sleep/inactivity
    /// boundary. IntentEngine calls this while capture is still active, then suspends
    /// us, then writes the boundary marker. This preserves a long quiet-reading dwell
    /// instead of silently deleting it when energy gating begins.
    func flushBeforeGap() {
        guard !isSuspended else { return }
        closeBurstIfDue(force: true)

        let now = MonotonicClock.now
        closeDwell(at: now)
        resetTransientState()
    }

    /// A capture boundary must remove BOTH the timer and the global scroll monitor.
    /// Keeping the event-driven monitor armed was cheap, but incorrect for a manual
    /// pause: scroll events could still open a burst and later leak it across the gap.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        housekeeping?.invalidate()
        housekeeping = nil
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        scrollMonitor = nil
        resetTransientState()
    }

    func resume() {
        guard isSuspended, bus != nil else { return }
        isSuspended = false
        lastMouse = NSEvent.mouseLocation
        resetTransientState()
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
        }
        // .common mode (repo idiom, DragMonitor/ClipboardHistoryStore): default-mode
        // timers pause during menu tracking — fatal for a menu-bar app whose engine
        // is controlled FROM the status menu.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Keep D1's tolerance on every initial/re-arm path.
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        housekeeping = t
    }

    private func resetTransientState() {
        burstOpen = false
        burstStart = 0
        burstLast = 0
        burstNet = 0
        burstAbs = 0
        burstFlips = 0
        burstLastSign = 0
        burstApp = nil
        stationarySince = nil
        stationaryApp = nil
    }

    // MARK: Scroll bursts

    private func handleScroll(_ event: NSEvent) {
        guard !isSuspended else { return }
        let now = MonotonicClock.now
        let dy = Double(event.scrollingDeltaY)

        if burstOpen, now - burstLast > burstGap {
            closeBurstIfDue(force: true)
        }
        if !burstOpen {
            burstOpen = true
            burstStart = now
            burstNet = 0; burstAbs = 0; burstFlips = 0; burstLastSign = 0
            burstApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }

        burstLast = now
        burstNet += dy
        burstAbs += abs(dy)
        if abs(dy) > scrollDeadband {
            let sign = dy > 0 ? 1 : -1
            if burstLastSign != 0, sign != burstLastSign { burstFlips += 1 }
            burstLastSign = sign
        }
    }

    private func closeBurstIfDue(force: Bool = false) {
        guard burstOpen else { return }
        let now = MonotonicClock.now
        guard force || now - burstLast > burstGap else { return }
        burstOpen = false

        // Sub-4pt bursts are trackpad noise, not reading behaviour.
        guard burstAbs >= 4 else { return }
        // Stamped with PUBLISH time, not burstLast: the bus guarantees monotonic
        // event time (ARCHITECTURE §4), and a burst detected ≤ ~1.3 s late (gap +
        // tick) would otherwise time-travel behind already-published events. The
        // shift is noise at τ ≥ 60 s (<2% decay error); `duration` still describes
        // the gesture itself.
        bus?.publish(.live(kind: .scrollBurst, scroll: ScrollBurstPayload(
            app: burstApp,
            duration: ((burstLast - burstStart) * 100).rounded() / 100,
            netDeltaY: (burstNet * 10).rounded() / 10,
            totalAbsDeltaY: (burstAbs * 10).rounded() / 10,
            directionChanges: burstFlips)))
    }

    // MARK: Housekeeping tick (burst timeout + dwell detection)

    private func tick() {
        guard !isSuspended else { return }
        closeBurstIfDue()

        let now = MonotonicClock.now
        let loc = NSEvent.mouseLocation
        let moved = hypot(loc.x - lastMouse.x, loc.y - lastMouse.y) > jitterDeadband

        if moved {
            closeDwell(at: now)
            lastMouse = loc
        } else if stationarySince == nil {
            stationarySince = now
            stationaryApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    /// An app activation is a hard semantic boundary for mouse-stationary dwell.
    /// Close any qualifying interval against the app captured at dwell start, then
    /// let the next housekeeping tick begin a fresh interval in the newly active app.
    /// Called by AppFocusSensor before it publishes the focus transition. This keeps
    /// the closing dwell attached to the application observed at dwell start.
    func prepareForAppActivation() {
        guard !isSuspended else { return }
        closeDwell(at: MonotonicClock.now)
        lastMouse = NSEvent.mouseLocation
    }

    private func closeDwell(at now: TimeInterval) {
        if let since = stationarySince, now - since >= dwellMinimum {
            let duration = now - since
            // Mouse-stationary typing is not reading dwell. This permission-free
            // system counter lets us suppress any interval containing a key-down;
            // it stores no key identity and installs no keyboard monitor.
            let keyQuiet = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .keyDown)
            guard !keyQuiet.isFinite || keyQuiet + 0.25 >= duration else {
                stationarySince = nil
                stationaryApp = nil
                return
            }
            bus?.publish(.live(kind: .dwell, dwell: DwellPayload(
                app: stationaryApp,
                seconds: (duration * 10).rounded() / 10)))
        }
        stationarySince = nil
        stationaryApp = nil
    }
}
