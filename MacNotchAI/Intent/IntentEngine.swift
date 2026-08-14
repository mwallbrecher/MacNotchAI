import AppKit
import ApplicationServices
import Combine

// THESIS — coordinator of the Computational Intent Pipeline (docs/thesis/ARCHITECTURE.md).
//
// M1: SignalBus + L1 sensors + trace recorder. M2: L2 feature extractor + L3 scorer,
// permanently wired to the bus so BOTH live events and replayed traces flow through
// scoring identically (that's the whole point of the replay harness). Sensors and
// recorder start/stop with the engine; the pipeline itself is always attached.
//
// The engine is INERT unless explicitly enabled — the app behaves exactly like the
// released main-branch build otherwise (this becomes the study's capture condition
// flag in M5; no A/B/C condition switcher is implemented). Enable via the Debug menu or:
//   defaults write com.wallbrecher.dragaway intentEngineEnabled -bool YES
//
// Permissions: the base sensors use none. The M2 SelectionSensor (Accessibility) is
// a SEPARATE opt-in (axSensorKey) — the single sanctioned gated API on this branch.
@MainActor
final class IntentEngine {

    static let shared = IntentEngine()

    static let enabledKey     = "intentEngineEnabled"
    static let verboseKey     = "intentEngineVerbose"
    static let axSensorKey    = "intentAXSensorEnabled"
    static let axPromptedKey  = "intentAXPromptRequested"
    static let readOnlyKey    = "intentReadOnly"
    static let pausedKey      = "intentPaused"
    private static let pausedAtKey = "intentPausedAt"

    let bus = SignalBus()
    let recorder = TraceRecorder()
    let extractor = FeatureExtractor()
    let scorer: IntentScorer
    let affordances: AffordanceController

    private var sensors: [IntentSensor] = []
    private var pipelineSink: AnyCancellable?
    private var verboseSink: AnyCancellable?
    private var activeObserver: NSObjectProtocol?
    private var recorderFailureObserver: NSObjectProtocol?
    private var affordanceFailureObserver: NSObjectProtocol?
    private var powerObservers: [NSObjectProtocol] = []
    private(set) var isRunning = false
    private var isSleeping = false
    private var sleepStartedAt: TimeInterval?
    private var isInactivityGated = false
    private var isClosingGap = false
    private var affordancesArmed = false
    private var captureFailed = false
    private var selectionCoverageUnavailable = false

    /// Marks work time vs. awake-but-untouched time, and suspends the periodic
    /// sensors while nobody is at the machine (ActivityMonitor). Not in `sensors`:
    /// it governs them, so it must outlive their suspension.
    private let activity = ActivityMonitor()

    private init() {
        let loadedConfig = IntentConfig.load()
        // A persisted study always resumes with the same compiled model/policy. Only
        // participant languages survive relaunch. This prevents an edited config or a
        // reused pilot install from changing thresholds/weights halfway through a run.
        let persistedStudyLanguages = StudyMode.participantLanguages
        let launchStudyLanguages = persistedStudyLanguages.isEmpty
            ? loadedConfig.userLanguages : persistedStudyLanguages
        let launchConfig = StudyMode.isActive
            ? IntentConfig.studyConfiguration(userLanguages: launchStudyLanguages)
            : loadedConfig
        if StudyMode.isActive {
            // One-time migration for an already-armed pre-hardening pilot.
            if persistedStudyLanguages.isEmpty {
                StudyMode.participantLanguages = launchConfig.userLanguages
            }
            launchConfig.save()
        }
        let scorer = IntentScorer(config: launchConfig)
        self.scorer = scorer
        affordances = AffordanceController(scorer: scorer, extractor: extractor)
        Self.applyLanguageConfig(scorer.config)
        // L2/L3 are ALWAYS attached: live capture and trace replay take the same
        // path. L4/L5 (the affordance surface) only reacts while the engine is
        // RUNNING — a replay must never pop UI out of historical events.
        extractor.emit = { [weak self] evidence in self?.scorer.add(evidence) }
        pipelineSink = bus.events.sink { [weak self] event in
            guard let self else { return }
            // Suspension should stop every sensor at source. This guard is the second
            // line of defence for an already-queued callback: it may remain visible in
            // the raw trace for diagnosis, but can never mutate scorer state or surface
            // an affordance across a pause/sleep/inactivity boundary.
            if self.captureIsSuppressed, event.kind != .activity { return }
            self.extractor.handle(event)
            // Read-only mode: sensors + scorer + recorder run, but the affordance
            // surface never reacts — pure capture, no whisper. This is the formative
            // (Phase 1) and general data-collection mode; observing behaviour must
            // not be perturbed by the thing we're studying.
            if self.isRunning, !self.isReadOnly,
               !self.captureIsSuppressed, !self.isClosingGap,
               event.kind != .activity {
                self.affordances.evaluate(at: event.t)
            }
        }
        // Re-check the AX grant whenever the app becomes active — the user coming
        // back after granting in System Settings is exactly this moment (there is
        // no dedicated "returned from Settings" notification). No permission polling.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileSensors() }
        }
        recorderFailureObserver = NotificationCenter.default.addObserver(
            forName: .intentTraceRecorderFailed, object: recorder, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, StudyMode.isActive, !self.captureFailed else { return }
                // No trace means no defensible B1/E record. Quiesce every producer and
                // surface immediately; a later retry opens both streams afresh.
                self.captureFailed = true
                self.suspendCaptureSources(flushDwell: false)
                self.disarmAffordances(reason: "trace_recorder_failed")
                let message = note.userInfo?["error"] as? String ?? "unknown recorder error"
                NotificationCenter.default.post(name: .intentStudyCaptureFailed,
                                                object: nil,
                                                userInfo: ["issue": "trace recorder: \(message)"])
            }
        }
        affordanceFailureObserver = NotificationCenter.default.addObserver(
            forName: .intentAffordanceLogFailed, object: affordances, queue: .main
        ) { [weak self] note in
            let message = note.userInfo?["error"] as? String ?? "unknown affordance log error"
            // `failLogging` can be reached inside the pipeline subscriber while the
            // SignalBus is still delivering its outer event. Hop one actor turn so
            // forced sensor closures and `capture_failed` are a new FIFO delivery,
            // then synchronise only after that boundary reached the recorder.
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, StudyMode.isActive, !self.captureFailed else { return }
                self.captureFailed = true
                self.suspendCaptureSources(flushDwell: false)
                // The controller already failed closed and unregistered its hotkeys.
                self.affordancesArmed = false
                self.bus.publish(.live(kind: .activity,
                                       activity: ActivityPayload(state: "capture_failed",
                                                                 seconds: 0)))
                self.flushRecorderBoundary()
                NotificationCenter.default.post(name: .intentStudyCaptureFailed,
                                                object: nil,
                                                userInfo: ["issue": "affordance log: \(message)"])
            }
        }
    }

    // MARK: Lifecycle

    /// Persisted research flag; setting it also starts/stops the live engine.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    /// Read-only (capture-only) mode: sensors + scorer + trace recorder run; the
    /// affordance surface (passive whisper, summon hotkey, affordance log) is fully
    /// suppressed. THE mode for formative observation and any data collection where
    /// the system must not influence what the user does. Persisted; toggling it while
    /// running attaches/detaches the affordance layer WITHOUT stopping a live
    /// recording.
    var isReadOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.readOnlyKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.readOnlyKey)
            guard isRunning else { return }
            if newValue {
                disarmAffordances(reason: "read_only")
            } else {
                armAffordancesIfAllowed()
            }
        }
    }

    /// Participant-controlled pause (E3) — the control the consent text promises:
    /// *"Pause recording at any time from the menu."*
    ///
    /// This is NOT the same thing as participant-controlled capture, and the
    /// difference decides the data's quality. Capture is ON by default and the
    /// participant may switch it off; the inverse (off by default, switched on to
    /// record) would let people record only what they consider interesting, which
    /// systematically excludes the quiet reader — the case this study exists to
    /// observe. Same control, opposite default, entirely different dataset.
    ///
    /// A pause is written into the trace as an explicit marker, so a gap in the data
    /// is KNOWN rather than merely absent. A silent gap is indistinguishable from a
    /// crash, and would quietly corrupt any rate computed over elapsed time.
    var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pausedKey) }
        set {
            let was = UserDefaults.standard.bool(forKey: Self.pausedKey)
            guard was != newValue else { return }
            if newValue {
                // Flush legitimate pre-gap dwell/scroll state first. Then persist the
                // pause and invalidate every event source before writing the boundary,
                // so no sensor completion can appear after `paused`.
                if isRunning { suspendCaptureSources(flushDwell: true) }
                UserDefaults.standard.set(true, forKey: Self.pausedKey)
                // Persist wall time: a manual pause can span app relaunches or a reboot,
                // where a process/session-relative monotonic origin is incomparable.
                UserDefaults.standard.set(MonotonicClock.wallNow, forKey: Self.pausedAtKey)
                isInactivityGated = false
                disarmAffordances(reason: "paused")
                if isRunning {
                    bus.publish(.live(kind: .activity,
                                      activity: ActivityPayload(state: "paused", seconds: 0)))
                    flushRecorderBoundary()
                }
                // Decay windows use process uptime, which does not describe a pause
                // spanning relaunch/sleep. Never let pre-pause evidence survive it.
                extractor.reset()
                scorer.reset()
            } else {
                let started = UserDefaults.standard.double(forKey: Self.pausedAtKey)
                let duration = started > 0 ? max(0, MonotonicClock.wallNow - started) : 0
                if isRunning {
                    extractor.reset()
                    scorer.reset()
                    // Marker first while every source is still down; only afterwards
                    // may a resumed sensor publish.
                    bus.publish(.live(kind: .activity,
                                      activity: ActivityPayload(state: "resumed",
                                                                seconds: duration)))
                    flushRecorderBoundary()
                }
                UserDefaults.standard.set(false, forKey: Self.pausedKey)
                UserDefaults.standard.removeObject(forKey: Self.pausedAtKey)
                if isRunning, !isSleeping { resumeCaptureSources() }
            }
        }
    }

    func start() {
        guard !isRunning else { return }

        // A persisted study must recover recording on every launch before any live
        // sensor is armed. If the file cannot be opened, stay fully quiescent and
        // leave the recorder in its visible `.failed` state instead of collecting an
        // unrecorded, analytically invisible interval.
        if StudyMode.isActive, !recorder.isRecording {
            do {
                try recorder.startOrThrow(bus: bus)
            } catch {
                print("[intent] study recorder startup failed: \(error.localizedDescription)")
                return
            }
        }

        captureFailed = false
        let clipboard = ClipboardSensor()
        let dwell = DwellSensor()
        let appFocus = AppFocusSensor { [weak clipboard, weak dwell] bundleID in
            // One NSWorkspace observer now defines the semantic order explicitly:
            // pending copy → closing dwell → focus transition. Separate observers
            // have no documented ordering guarantee and could miss the strongest
            // copy_then_translator_switch evidence on a rapid app switch.
            clipboard?.prepareForAppActivation(bundleID: bundleID)
            dwell?.prepareForAppActivation()
        }
        sensors = [clipboard, appFocus, dwell]
        isRunning = true
        isSleeping = false
        sleepStartedAt = nil
        isInactivityGated = false
        installPowerObservers()

        // A persisted pause must be completely event-free across relaunch. In
        // particular, AppFocus's new denominator baseline may not be written until
        // after the explicit `resumed` boundary.
        let startsPaused = isPaused
        if startsPaused { sensors.forEach { $0.startSuspended(bus: bus) } }
        else { sensors.forEach { $0.start(bus: bus) } }

        // Idle gating. While the participant is away, every periodic sensor stands
        // down and only ActivityMonitor's (event-driven, free) input monitor stays
        // armed — the largest single energy saving in a long deployment, and the
        // source of the work-vs-absence segmentation the analysis needs.
        activity.onGatingChange = { [weak self] shouldGate in
            guard let self, self.isRunning else { return }
            // `active` is written before ActivityMonitor asks us to re-arm. If that
            // synchronous write fails, the recorder callback sets `captureFailed`;
            // never continue by restarting sensors into an unrecorded interval.
            guard !self.isPaused, !self.isSleeping, !self.captureFailed else { return }
            if shouldGate {
                guard !self.isInactivityGated else { return }
                self.suspendCaptureSources(flushDwell: true, includeActivity: false)
                self.isInactivityGated = true
                self.disarmAffordances(reason: "extended_inactivity")
            } else {
                guard self.isInactivityGated else { return }
                self.resumeCaptureSources(capturePendingClipboard: true)
            }
        }

        // Configure ActivityMonitor even for a persisted pause. `start` and the
        // following synchronous `suspend` cannot interleave with a timer callback, and
        // this leaves the bus attached so a later participant resume can truly re-arm
        // inactivity detection without restarting the engine.
        activity.start(bus: bus)

        if startsPaused {
            activity.suspend()
        } else {
            reconcileSensors()   // attaches SelectionSensor when flag + grant align
            armAffordancesIfAllowed()
        }

#if DEBUG
        if UserDefaults.standard.bool(forKey: Self.verboseKey) {
            verboseSink = bus.events.sink { [weak self] event in
                guard let self else { return }
                let top = self.scorer.scores(at: event.t).first
                let topDesc = top.map {
                    "\($0.intentClass.rawValue) \(String(format: "%.0f%%", $0.probability * 100))"
                } ?? "-"
                print("[intent] \(event.kind.rawValue)  → top: \(topDesc)")
            }
        }
#endif
    }

    /// Stops sensors AND any running recording. Also used to quiesce the live
    /// pipeline before a trace replay (live + replayed timelines must not mix).
    func stop() {
        guard isRunning else {
            // Covers a manually started recorder and a partially completed startup.
            recorder.stop()
            return
        }
        // Close denominator and gesture state while the recorder is still attached.
        // prepareForTermination/Withdrawal may already have done this; every sensor's
        // suspended guard makes the second call harmless.
        suspendCaptureSources(flushDwell: !isPaused && !isSleeping)
        isRunning = false
        removePowerObservers()
        disarmAffordances()
        recorder.stop()
        activity.stop()
        sensors.forEach { $0.stop() }
        sensors = []
        verboseSink = nil
        isSleeping = false
        sleepStartedAt = nil
        isInactivityGated = false
        captureFailed = false
        selectionCoverageUnavailable = false
    }

    /// Aligns the running sensor set with the desired one. Idempotent and cheap —
    /// called on engine start, on axSensorEnabled changes, whenever the app becomes
    /// active, and on debug-menu open. This fixes the grant-after-enable dead end:
    /// the SelectionSensor attaches the moment flag AND trust are actually true,
    /// without restarting the engine (a restart would kill a running recording).
    func reconcileSensors() {
        guard isRunning, !captureFailed else { return }
        let permissionExpected = axSensorEnabled
        let trusted = AXIsProcessTrusted()
        let wantSelection = permissionExpected && trusted
        let haveIndex = sensors.firstIndex { $0 is SelectionSensor }
        let mayPoll = !isPaused && !isSleeping && !isInactivityGated
        if wantSelection, haveIndex == nil, mayPoll {
            let sensor = SelectionSensor()
            sensor.onTrustLost = { [weak self] in self?.handleSelectionTrustLost() }
            sensor.start(bus: bus)
            sensors.append(sensor)
            markSelectionCoverageAvailable()
        } else if wantSelection, let i = haveIndex, mayPoll {
            sensors[i].resume()
            markSelectionCoverageAvailable()
        } else if !wantSelection, let i = haveIndex {
            sensors[i].stop()
            sensors.remove(at: i)
            if permissionExpected { markSelectionCoverageUnavailable(notify: true) }
        } else if permissionExpected, !trusted, mayPoll {
            // Initial setup without a grant is recorded as a coverage gap. The setup
            // status dialog owns the warning, avoiding a duplicate modal here.
            markSelectionCoverageUnavailable(notify: false)
        }
    }

    private func handleSelectionTrustLost() {
        guard isRunning, !captureFailed else { return }
        reconcileSensors()
    }

    private func markSelectionCoverageUnavailable(notify: Bool) {
        guard !selectionCoverageUnavailable else { return }
        selectionCoverageUnavailable = true
        if !captureIsSuppressed {
            bus.publish(.live(kind: .activity,
                              activity: ActivityPayload(state: "accessibility_unavailable",
                                                        seconds: 0)))
            flushRecorderBoundary()
        }
        if notify, StudyMode.isActive {
            NotificationCenter.default.post(
                name: .intentStudyCaptureFailed,
                object: nil,
                userInfo: ["issue": "Accessibility permission was removed; selection and quiet-reader coverage are incomplete"])
        }
    }

    private func markSelectionCoverageAvailable() {
        guard selectionCoverageUnavailable else { return }
        selectionCoverageUnavailable = false
        guard !captureIsSuppressed else { return }
        bus.publish(.live(kind: .activity,
                          activity: ActivityPayload(state: "accessibility_restored",
                                                    seconds: 0)))
        flushRecorderBoundary()
    }

    // MARK: Capture lifecycle (pause · inactivity · sleep/wake)

    private var captureIsSuppressed: Bool {
        isPaused || isSleeping || isInactivityGated || captureFailed
    }

    /// Stops every periodic timer and every global/workspace monitor. Clipboard and
    /// dwell get a chance to close observable pre-gap state while capture is still
    /// live; the `isClosingGap` guard prevents those observations from popping UI.
    private func suspendCaptureSources(flushDwell: Bool,
                                       includeActivity: Bool = true) {
        isClosingGap = true
        if flushDwell {
            sensors.compactMap { $0 as? DwellSensor }.forEach { $0.flushBeforeGap() }
        }
        // A copy may occur inside the poll interval. Reconcile it before AppFocus
        // closes so its source event remains inside the segment that provides context.
        sensors.compactMap { $0 as? ClipboardSensor }.forEach { $0.flushBeforeGap() }
        // AppFocus closes last so every forced pre-gap observation remains inside the
        // app segment that provides its denominator/context.
        sensors.compactMap { $0 as? AppFocusSensor }.forEach { $0.flushBeforeGap() }
        sensors.forEach { $0.suspend() }
        if includeActivity { activity.suspend() }
        isClosingGap = false
    }

    /// Re-arm after a known gap. ActivityMonitor goes first: its immediate
    /// permission-free CGEventSource check may decide the machine is still in extended
    /// inactivity, in which case periodic sensors remain down.
    private func resumeCaptureSources(capturePendingClipboard: Bool = false) {
        guard isRunning, !isPaused, !isSleeping, !captureFailed else { return }
        isInactivityGated = false
        activity.resume()
        if !isInactivityGated {
            for sensor in sensors {
                if capturePendingClipboard, let clipboard = sensor as? ClipboardSensor {
                    clipboard.resumeAfterExtendedInactivity()
                } else {
                    sensor.resume()
                }
            }
            reconcileSensors()
        }
        armAffordancesIfAllowed()
    }

    private func armAffordancesIfAllowed() {
        guard isRunning, !isReadOnly, !isPaused, !isSleeping, !isInactivityGated,
              !captureFailed, !affordancesArmed else { return }
        affordances.start()
        // `start()` deliberately fails closed when its JSONL cannot be opened. Never
        // mark the surface armed merely because the call returned: that would leave
        // the study looking healthy while all B1/E interaction data is absent.
        affordancesArmed = affordances.logHealth.isHealthy
    }

    private func disarmAffordances(reason: String = "controller_stopped") {
        guard affordancesArmed || affordances.logHealth.state != .stopped else { return }
        affordances.stop(reason: reason)
        affordancesArmed = false
    }

    /// Synchronise lifecycle boundaries immediately. Periodic 30-second syncing caps
    /// ordinary crash loss; pause/sleep/failure transitions are stronger audit edges
    /// and must be durable before control returns to the participant or the OS.
    private func flushRecorderBoundary() {
        do { try recorder.flush() }
        catch {
            // `TraceRecorder.flush()` owns fail-closed health and posts the recorder
            // failure notification; do not manufacture a second state transition here.
            print("[intent] boundary flush failed: \(error.localizedDescription)")
        }
    }

    private func installPowerObservers() {
        guard powerObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDidWake() }
        }
        powerObservers = [willSleep, didWake]
    }

    private func removePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.forEach { center.removeObserver($0) }
        powerObservers = []
    }

    /// Explicit API for the NSWorkspace power observer and deterministic lifecycle
    /// tests. The sleep boundary supersedes inactivity; all sources are down before the
    /// marker is written.
    func handleWillSleep() {
        guard isRunning, !isSleeping else { return }
        if !isPaused {
            suspendCaptureSources(flushDwell: true)
        } else {
            // Persisted/manual pause already has sources down, but keep this idempotent.
            suspendCaptureSources(flushDwell: false)
        }
        isInactivityGated = false
        isSleeping = true
        // Sleep advances wall time but not every uptime clock; the event boundary uses
        // monotonic `t`, while the human-readable gap duration uses wall time.
        sleepStartedAt = MonotonicClock.wallNow
        disarmAffordances(reason: "sleep")
        bus.publish(.live(kind: .activity,
                          activity: ActivityPayload(state: "sleep", seconds: 0)))
        flushRecorderBoundary()
        // Uptime may pause during sleep. Clear the pre-sleep inference state at this
        // explicit boundary so stale evidence cannot still look fresh after wake.
        extractor.reset()
        scorer.reset()
    }

    /// Writes `wake` before re-arming anything, resets all gap-sensitive baselines via
    /// sensor resume, and re-evaluates AX trust. A manual pause survives the wake and
    /// therefore intentionally leaves every source down.
    func handleDidWake() {
        guard isRunning, isSleeping else { return }
        let duration = sleepStartedAt.map { max(0, MonotonicClock.wallNow - $0) } ?? 0
        bus.publish(.live(kind: .activity,
                          activity: ActivityPayload(state: "wake", seconds: duration)))
        flushRecorderBoundary()
        isSleeping = false
        sleepStartedAt = nil
        affordances.resetExposureStateAfterSleep()

        if !isPaused { resumeCaptureSources() }
    }

    /// Ordered shutdown hook for AppDelegate.applicationWillTerminate. Capture sources
    /// are invalidated first, then the affordance log and trace recorder are closed.
    /// `stop()` owns the actual FileHandle close calls and is idempotent, so this stays
    /// safe if normal teardown has already run.
    func prepareForTermination() {
        guard isRunning else {
            // A recorder may have been started manually after the engine stopped.
            recorder.stop()
            return
        }
        suspendCaptureSources(flushDwell: !isPaused && !isSleeping)
        disarmAffordances(reason: "terminated")
        bus.publish(.live(kind: .activity,
                          activity: ActivityPayload(state: "terminated", seconds: 0)))
        flushRecorderBoundary()
        stop()
    }

    /// Writes an explicit terminal boundary while Study provenance is still active.
    /// The caller may then disable the engine and clear StudyMode without making a
    /// voluntary withdrawal analytically indistinguishable from a crash.
    func prepareForWithdrawal() {
        guard isRunning else { return }
        suspendCaptureSources(flushDwell: !isPaused && !isSleeping)
        disarmAffordances(reason: "withdrawn")
        bus.publish(.live(kind: .activity,
                          activity: ActivityPayload(state: "withdrawn", seconds: 0)))
        flushRecorderBoundary()
    }

    /// Clean slate for detectors, evidence AND the bus buffer — call before
    /// replaying a trace (stale live events carry timestamps far ahead of the
    /// recorded timeline and would corrupt windowing/dedup).
    func resetPipeline() {
        bus.reset()
        extractor.reset()
        scorer.reset()
    }

    func reloadConfig() {
        let loaded = IntentConfig.load()
        scorer.config = StudyMode.isActive
            ? .studyConfiguration(userLanguages:
                StudyMode.participantLanguages.isEmpty
                    ? loaded.userLanguages : StudyMode.participantLanguages)
            : loaded
        if StudyMode.isActive { scorer.config.save() }
        Self.applyLanguageConfig(scorer.config)
        affordances.configReloaded()   // re-seed mutes; tier/θ are read live
    }

    /// Establishes the new participant boundary while the engine is stopped. This is
    /// deliberately stronger than `setUserLanguages`: it also resets every weight,
    /// prior, threshold, tier, mute and policy cooldown/rate-limit slot.
    func configureNewStudy(userLanguages: [String]) {
        precondition(!isRunning, "study configuration must be frozen before capture starts")
        scorer.config = .studyConfiguration(userLanguages: userLanguages)
        scorer.config.save()
        Self.applyLanguageConfig(scorer.config)
        affordances.resetForNewStudy()
    }

    /// Push the configured language repertoire into IntentText. Empty config ⇒ nil
    /// override ⇒ IntentText falls back to the machine locale (right for a distributed
    /// build, wrong for a study session — see IntentConfig.userLanguages).
    private static func applyLanguageConfig(_ config: IntentConfig) {
        let langs = config.normalisedUserLanguages
        IntentText.userLanguagesOverride = langs.isEmpty ? nil : langs
    }

    /// What "foreign" currently means, for the debug menu — the study operator must be
    /// able to see, before a session, whose languages the flag is judging against.
    var languageSourceDescription: String {
        let langs = IntentText.userLanguages.sorted().joined(separator: ", ")
        return IntentText.userLanguagesOverride == nil
            ? "⚠️ from THIS MACHINE's locale: [\(langs)] — set the participant's languages for a study session"
            : "from IntentConfig (explicit): [\(langs)]"
    }

    // MARK: Participant language repertoire (study menu)
    //
    // Codes are ISO-639-1 exactly as NLLanguageRecognizer reports them — all of the
    // below were verified to detect at confidence 1.00 on sample text, so every entry
    // here actually does something.
    //
    // NB "Indian" is not a language: the detector distinguishes Hindi, Tamil, Bengali,
    // … individually, so the operator ticks the specific one(s) the participant reads.

    static let commonLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("de", "German"), ("es", "Spanish"), ("fr", "French"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"),
        ("tr", "Turkish"), ("ru", "Russian"), ("ar", "Arabic"), ("zh", "Chinese"),
        ("ja", "Japanese"), ("ko", "Korean"),
    ]

    static let indianLanguages: [(code: String, name: String)] = [
        ("hi", "Hindi"), ("bn", "Bengali"), ("ta", "Tamil"), ("te", "Telugu"),
        ("mr", "Marathi"), ("gu", "Gujarati"), ("kn", "Kannada"), ("ml", "Malayalam"),
        ("pa", "Punjabi"), ("ur", "Urdu"),
    ]

    /// nil override ⇒ we are still on the machine locale (never valid for a session).
    var hasExplicitLanguages: Bool { IntentText.userLanguagesOverride != nil }

    func isLanguageSelected(_ code: String) -> Bool {
        hasExplicitLanguages && IntentText.userLanguages.contains(code)
    }

    /// Every stimulus except Task 1's is in English, so a repertoire without English
    /// would make ordinary Task 2/3 copies flag as foreign — spurious translation
    /// evidence inside the comprehension/discovery tasks.
    var languageConfigWarning: String? {
        guard hasExplicitLanguages else { return nil }
        return IntentText.userLanguages.contains("en")
            ? nil
            : "⚠️ English not set — Task 2/3 copies will falsely flag as foreign"
    }

    func toggleLanguage(_ code: String) {
        var langs = hasExplicitLanguages ? IntentText.userLanguages : []
        if langs.contains(code) { langs.remove(code) } else { langs.insert(code) }
        setUserLanguages(langs.sorted())
    }

    /// Persists to IntentConfig.json (same file the operator could hand-edit) and
    /// pushes the override into IntentText immediately.
    func setUserLanguages(_ codes: [String]) {
        // Participant languages are part of the frozen cohort configuration. Correct
        // them by starting a new researcher-led setup, which archives the old cohort.
        guard !StudyMode.isActive else { return }
        scorer.config.userLanguages = IntentConfig.studyConfiguration(
            userLanguages: codes).userLanguages
        scorer.config.save()
        Self.applyLanguageConfig(scorer.config)
    }

    /// Back to the machine locale — correct for a distributed build, never for a session.
    func clearUserLanguages() { setUserLanguages([]) }

    /// Score snapshot with "why" decomposition. `at` defaults to now, which equals
    /// event time for live capture; pass the trace's last event time after a replay
    /// (using wall clock there would decay everything to zero).
    func scoresDescription(at t: TimeInterval? = nil) -> String {
        scorer.describeScores(at: t ?? MonotonicClock.now)
    }

    // MARK: Accessibility opt-in (SelectionSensor only)

    var axSensorEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.axSensorKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.axSensorKey)
            reconcileSensors()   // NEVER stop()/start() here — that killed recordings
        }
    }

    /// One system dialog on first request (registers the app in the Accessibility
    /// list); afterwards deep-link to the pane — macOS never re-shows the dialog.
    /// Same single-dialog flow the released app used before going permission-free.
    func requestAXPermission() {
        if !UserDefaults.standard.bool(forKey: Self.axPromptedKey) {
            UserDefaults.standard.set(true, forKey: Self.axPromptedKey)
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        } else {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}
