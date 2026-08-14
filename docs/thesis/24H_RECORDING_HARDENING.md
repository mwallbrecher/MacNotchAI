# 24-hour study-recording hardening

**Branch:** `thesis`

**Date:** 2026-08-13

**Purpose:** turn the A1–A3, B1–B4, C1–C6, D1–D4 and E1–E3 prototype into a
fail-visible instrument suitable for a 24-hour engineering pilot before participant deployment.

This note is the handoff contract for the exact study artefact. It separates properties proved by
code/build checks from behaviour that still has to be exercised on the signed DMG and a real Mac.

## Agreed scope

The owner confirmed four study-design boundaries during review:

1. Consent is handled with the researcher before recording. The app records the accepted wording,
   version and timestamp for provenance, but a technical first-launch consent lock is not a validity
   requirement.
2. Normal AI-action traffic follows the provider configured in Dragaway. It is not part of the thesis
   recorder or exported study bundle and is outside this instrumentation review.
3. `DocumentReader` may briefly read local AX content to decide whether an action is available, then
   discard it. Raw document content must never enter a trace, affordance log or study export.
4. Every participant uses one assigned ID on their own installation. Export filtering across several
   participants on one macOS account is therefore not required. When researcher setup is deliberately
   repeated on a pilot Mac, previous recorder artefacts are moved to a non-exported `prestudy-*`
   archive before the new ID is armed.

## Implemented safety boundaries

### Study artefact cannot become a Sparkle release

- Both app target configurations compile with `THESIS_STUDY_BUILD` and include the Study controls.
- The Thesis project has no Sparkle package product or embedded Sparkle framework.
- The Study bundle contains `DragawayStudyBuild = true` and
  `SUEnableAutomaticChecks = false`; it contains neither `SUFeedURL` nor `SUPublicEDKey`.
- `StudyBuild.invariantViolations` checks those facts in the built bundle and the Study menu displays
  an unsafe-build warning if any invariant fails.
- `scripts/release.sh` exits before touching `build/`, signing, notarisation or `appcast.xml` unless
  the checked-out branch is exactly `main`. It also refuses a source plist carrying the Study marker.
- The Study DMG is built and distributed manually. It is never uploaded as a GitHub release and never
  passed to Sparkle's `generate_appcast`.
- The public product Clipboard History recorder is compiled into the shared app but forcibly remains
  off in a Study build; its previous preferences/history are neither changed nor exported. This avoids
  a second, raw-content clipboard store alongside the content-minimised Study sensor.

This protects both directions: a Study build cannot consume a public Main update, and the repository's
normal release path cannot advertise a Study build to public clients.

### Relaunch and login recovery

- Study setup registers the signed main app through `SMAppService.mainApp`; the menu reports whether
  login launch is enabled or still requires approval.
- Accessibility collection is enabled during the researcher-led setup and the macOS permission prompt
  is requested when needed.
- An armed Study relaunch restarts the engine and trace recorder without another setup action.
- A persisted participant pause remains paused after relaunch; restart never silently resumes capture.

`SMAppService` means **after the participant logs in**, not before macOS login. Registration also has to
be approved in System Settings when macOS reports `requiresApproval`. The DMG must therefore be copied
to `/Applications` before setup and the enabled status must be checked while the researcher is present.
It is a login/reboot mechanism, **not a crash or force-quit watchdog**: after a process crash or manual
quit the app stays stopped until it is opened again (or the next login). That interval cannot be
recorded. A later trace starts a new process/session with its own wall-clock start, so the interval is
detectable by comparing segment boundaries, but an abrupt kill does not manufacture a precise
`capture_failed` event. A writer I/O failure does produce that durable marker on the next healthy start.

### Recording, rotation and export integrity

- Trace files use schema **v4**. Each file starts with a typed header containing app version, local
  day, start wall time and uptime, process/session UUID, PID, participant/consent provenance and any
  repaired crash tails. Every later line is one typed `SignalEvent` with the same session/PID,
  `t == uptime`, wall time, optional clock-discontinuity record and exactly one payload matching its
  signal kind.
- Files are partitioned at every process start and local day boundary as
  `trace-YYYYMMDD-HHmmss-SSS.jsonl`. This is safer than appending different launches to one daily
  file while retaining a direct `day` field for analysis.
- The affordance stream is append-only schema **v4**. Every row carries a log-session UUID,
  process/session identity, participant/consent provenance, event type, exact class probabilities,
  the complete decayed evidence vector and any interaction/action/outcome fields relevant to that
  event.
- Both writers synchronize at most every 30 seconds even when no new event arrives, and immediately
  at pause, sleep, wake, termination, withdrawal and capture-failure boundaries. A write or sync
  error changes health to failed, closes/disarms the corresponding source and produces a visible
  warning; the app never continues presenting unlogged affordances.
- Relaunch repairs only the final interrupted JSONL fragment: a complete JSON object receives its
  missing newline; an incomplete tail is truncated and the repair is recorded. Interior corruption
  is never rewritten or silently skipped.
- Both tail-repair paths first synchronize a separate recovery journal and only then mutate the
  interrupted file. A trace-writer failure is likewise journalled before shutdown; after a successful
  retry the first synchronized trace event is a `capture_failed` marker containing the observable wall
  time of the gap.
- Export first synchronizes live writers and validates every non-empty JSONL line against the exact
  v4/v4 semantic schema. It canonical-decodes/re-encodes typed rows (so unknown `rawText`, path or
  similar keys cannot hitchhike into the archive), exports the durable configuration snapshot frozen
  at deployment (and verifies an active scorer against it), verifies staged file names/sizes and the
  ZIP container bounds, and deletes a failed archive. An active unhealthy study cannot export as if
  complete. After withdrawal, surviving valid files can be exported only with a prominent
  `INCOMPLETE CAPTURE — PARTIAL EXPORT ONLY` manifest warning.
- The manifest separately counts `accepted` rows without `action_started`, started actions without a
  terminal outcome and `controller_stopped:*` actions whose later provider outcome was no longer
  observed. Crash-boundary evidence remains exportable, but it can no longer look lifecycle-complete.
- No cross-participant filtering is performed, per the agreed one-ID/one-installation protocol.
  Researcher setup losslessly archives existing trace/log, recovery and AX-probe artefacts before the
  participant starts, so one export cohort remains in the active folder.
- Setup and every active-study relaunch reconstruct a **canonical frozen configuration**: compiled
  weights, priors, taus, thresholds, balanced tier, rate limits and empty mutes. Only the explicitly
  selected participant languages survive. Policy cooldown/rate-limit state and prompt quota reset at
  the new-cohort boundary, and active export rejects a non-canonical in-memory config.

### Pause, inactivity and sleep/wake integrity

- Participant pause is persisted. Before `paused`, pending copy/scroll/dwell work and the current app
  segment are closed while affordance evaluation is suppressed; then every timer, global monitor and
  in-flight AX generation is invalidated. The RAM content vault and inference state are cleared.
  `resumed` is durable before sensors receive a fresh baseline. A relaunch while paused attaches
  sensors without publishing or arming them.
- App-focus data contains explicit `baseline`, `activated` and `segment_end` transitions. This makes
  time-in-app denominators reconstructible instead of leaving the final app segment open at every
  pause, sleep, quit or inactivity gate.
- Dwell keeps the app observed at dwell start and closes/resets on application activation. It can no
  longer attribute a stationary Safari interval to Notes after a keyboard app switch.
- One app-activation observer now defines the semantic order `pending clipboard → closing dwell →
  focus transition`. Rapid copy→DeepL therefore no longer relies on the unspecified callback order of
  independent `NSWorkspace` observers.
- Activity is intentionally two-stage: `inactive` after 60 seconds means ambiguous quiet time and
  does **not** stop sensors; `extended_inactivity` after five minutes gates periodic work. Keyboard
  return is detected permission-free via `CGEventSource` at 1 Hz and writes `active` before sensors
  resume. If that first keyboard-only action changed the pasteboard (for example immediate ⌘C), the
  Clipboard sensor reconciles that one pending change after `active` rather than baselining it away.
  These markers segment the data but never become scorer evidence.
- Sleep closes sensor/app state before `sleep`; wake writes `wake` before fresh baselines. Evidence is
  reset across sleep, as is uptime-based affordance cooldown/rate-limit state. `terminated`,
  `withdrawn` and `capture_failed` are explicit terminal/broken boundaries.
- Accessibility revocation removes the Selection sensor, writes
  `accessibility_unavailable`, flushes it and shows a warning. A restored grant writes
  `accessibility_restored`. AX calls run on a serial utility queue with 0.5-second element timeouts,
  a one-request limit and lifecycle generations that discard late results.
- Mouse-stationary intervals containing a key-down are suppressed rather than classified as reading
  dwell. No key value is observed or stored; this uses only the permission-free system inactivity
  duration.

### Action and affordance-label integrity

- Comprehension resolves the narrowest current object in this order: AX selection, fresh matching
  pasteboard text, then a focused document snapshot. Translation requires a fresh matching foreign
  pasteboard object. Discovery uses an exact two-or-more-source RAM snapshot when possible, else a
  fresh pasteboard object or current document.
- The discovery vault is memory-only, lives for at most 90 seconds, holds at most three entries,
  bounds each entry to 6,000 characters and the total to 18,000, and clears on pause/stop/failure.
  Accept resolves the exact references; expiry/replacement fails rather than substituting content.
- AX selection/document targets record only PID, app, scope, content hash, character count and a
  hashed document identity. Accept re-reads off-main and requires the same app/PID, document, length
  and hash before materialising local content for the visible Dragaway session.
- Every ticker row logs its concrete action, actionability, one-based rank and shared interaction ID.
  `summon`/`ticker_closed` are explicit rank-0 surface records. The ticker closes with a logged reason
  on user close, displacement, stop or its 30-second timeout.
- `accepted` is written only after the overlay session revision changes, reaches a session stage and
  owns the expected file; an `.error` stage is not success. The deferred auto-run latch is bound to
  that exact session revision and is cleared on stop/failure, so it cannot run an old suggestion on a
  replacement file. Stale/replaced/expired targets, failed materialisation and failed session
  starts are `accept_failed` with a reason.
- The accepted suggestion is carried into the actual provider turn. Separate `action_started`,
  `action_completed` and categorical `action_failed` rows distinguish overlay acceptance from a
  technically completed AI response and record latency without prompt/result content. A
  `controller_stopped:*` `action_cancelled` row is an observation/capture boundary, not proof that the
  provider stopped; analyse it as right-censoring because a later provider callback is intentionally
  ignored after the study log session closes.
- In-situ prompts retain the originating interaction ID, channel, rank, action and outcome. A completed
  AI turn asks whether the result was useful; a dismissal or technical failure asks whether the
  suggestion was relevant/wanted. Both then ask intrusiveness and work context. Skips, timeouts and displacement are explicit. The
  quota is persisted per participant/day (maximum five, at least 15 minutes apart), and delayed
  prompts are cancelled on pause, stop or withdrawal.
- The signal bus drains nested publications through one non-reentrant FIFO, so every subscriber sees
  the same event order even when a failure callback publishes a boundary while handling another event.

## A1–E3 completion map

| Item | Implemented result | Proof boundary |
|---|---|---|
| A1 | All three intent classes resolve to current, verifiable objects; discovery supports real multi-source synthesis. | Golden resolver/vault checks plus manual accept matrix. |
| A2 | Quiet-reader selection/document probing is off-main and revalidated at accept; raw probe text is discarded. | Code/build; coverage remains app-specific. |
| A3 | All ticker rows expose the action or state that no verifiable source exists. | Code/build and manual ticker check. |
| B1 | Every affordance record carries all class scores and the full unthresholded evidence decomposition. | Typed v4 affordance schema/export validator. |
| B2 | Participant, study, consent, process and session identity are stamped at source. | v4/v4 validators reject missing provenance. |
| B3 | Manual Desktop ZIP contains validated traces, log, exact config and manifest; nothing uploads. | Deterministic schema seam plus manual ZIP inspection. |
| B4 | Researcher-led setup records consent wording version/time. Consent remains an organisational protocol, as agreed. | Setup/state and exported provenance. |
| C1 | Study app has no package/framework/feed/key path to Sparkle; public release script rejects non-`main` and Study marker. | Built-bundle inspection; repeat on signed DMG. |
| C2 | Ordering/decay uses uptime; wall time, clock steps and process sessions remain explicit. | v4 schema and live-stamp Golden check. |
| C3 | Active Study relaunch starts recorder before sensors; `SMAppService.mainApp` handles login launch and reports approval. It deliberately does not watchdog a crash/quit. | Code/build; signed-DMG reboot and force-quit tests still mandatory. |
| C4 | Menu distinguishes recording, paused and incomplete states and shows current-process successful event writes. | Manual status test. |
| C5 | New trace per process and local-day transition bounds corruption and keeps a day key. | Code plus controlled-midnight test. |
| C6 | Sleep/wake closes sources, clears stale evidence and re-evaluates AX before resuming. | Code; real sleep/wake test still mandatory. |
| D1 | All recurring study timers have tolerance, including 30-second writer sync timers. | Source/build inspection. |
| D2 | Selection and document AX IPC runs off-main with per-element timeout. | Source/build and Instruments stall check. |
| D3 | Selection polling backs off 1→3 seconds and resets on app switch, scroll or click. | Source/build and energy trace. |
| D4 | 60-second quiet marker plus five-minute polling gate preserves quiet reading better than treating silence as absence. | Activity markers plus physical energy test. |
| E1 | Linked, skippable, bounded usefulness-or-relevance/intrusiveness/context prompts, plus technical provider-turn outcomes. | v4 records and manual prompt matrix. |
| E2 | One-time/on-demand summon hint plus checked Carbon hotkey registration. | Golden/build plus hotkey-conflict test. |
| E3 | Persisted pause with ordered durable boundaries and no sensor/affordance capture inside the gap. | Suspended-start Golden check plus 5-minute pause test. |

## Why the 24-hour pilot is promising

The build now records enough independent structure to evaluate the thesis without raw content:

- translation has foreign-text, source app and copy→translator-switch evidence;
- comprehension has within-app re-reading, app-correct dwell and exact repeated-selection evidence;
- discovery has distinct-copy count (including several tabs of one app) and, within a shared detected
  language/model space, local topic-coherence embeddings;
- every shown/blocked/summoned/outcome row preserves the exact model state and policy threshold;
- explicit app segments and active/inactive/pause/sleep/process boundaries provide denominators;
- interaction IDs, provider-turn outcomes and in-situ responses provide labels for result usefulness
  or suggestion relevance, intrusiveness and work context.

That is a promising **engineering/feasibility dataset** **if** the 24-hour run demonstrates non-trivial event counts in the target
apps, successful action/prompt linkage and acceptable AX coverage. It is not yet evidence that the
detectors are accurate, that the displayed percentages are calibrated probabilities, or that enough
participant behaviour will trigger each class.

## Known ways the pilot can still produce weak or incomplete data

1. **AX coverage and dynamic documents.** Acrobat and some custom/Electron views may expose no usable
   text. Highly dynamic pages can change length/hash between show and accept, producing honest
   `accept_failed` rows but fewer successful quiet-reader actions. Report success rates per app/scope.
2. **Very long quiet reading.** At five minutes without input, polling is gated to save battery. The
   interval is explicitly marked, but selection/dwell detail after that boundary is absent until
   keyboard or pointer input resumes. Do not equate `inactive` or `extended_inactivity` with absence.
3. **Clipboard timing.** The sensor polls at 0.5 seconds and reconciles a pending change on app switch;
   the physical test must include rapid copy→DeepL switches and verify source/order in the trace.
4. **Crash/power-loss window.** Boundary transitions are synchronized immediately and ordinary data at
   most every 30 seconds (timer tolerance adds up to three seconds). Abrupt power loss can still lose
   the last unsynchronized OS-buffered records; tail recovery makes partial bytes visible but cannot
   recreate bytes never persisted.
5. **Cross-language coherence.** Apple's per-language embeddings have incompatible or unaligned vector
   spaces. Only same-detected-language pairs are compared; other pairs are skipped rather than assigned false low coherence, so bilingual
   discovery sessions can lack `topic_coherence` evidence.
6. **Content minimisation limits adjudication.** Because raw content is deliberately absent, offline
   analysis cannot independently judge semantic ground truth. It must use derived evidence, observed
   outcomes and in-situ labels.
7. **One identity per installation is operational.** Setup archives the previous active cohort but the
   exporter does not select individual rows by participant. Do not change participant ID outside a new
   researcher-led setup.
8. **Failure is visible, not impossible.** Disk exhaustion, permission revocation and hotkey conflicts
   stop/degrade capture and warn the user. A withdrawn failed run may yield a clearly marked partial
   archive; it must not be analysed as a complete 24-hour trace.
9. **Labels are missing-not-at-random.** Prompts occur only after dismissals or accepted actions that
   subsequently complete/fail, at most five per day and 15 minutes apart. `ignored`, `blocked`, ticker
   close and unsummoned moments have no ground-truth label. These data cannot by themselves support
   unbiased recall, AUC or calibration estimates.
10. **Summon is help-seeking, not ground truth.** The ranked percentage display can influence which row
    a participant chooses. Treat summon/action choice as observed behaviour, not proof that the top
    intent class was correct.
11. **Heuristic scopes remain coarse.** Re-reading is linked to an app bundle, not a browser tab or
    document unless a selection fingerprint is present. Dwell now excludes observed typing but still
    cannot prove the participant was reading.
12. **This build does not implement an experimental condition switch or task timer.** A single 24-hour
    recording can establish feasibility and provide RQ1-style signal/outcome material, but cannot alone
    estimate comparative RQ2 effects across chat/drag/intent conditions.
13. **The displayed scores are model estimates.** They are log-linear outputs tuned against synthetic
    scenarios, not empirically calibrated probabilities. Report reliability/Brier/ECE only after a
    suitable labelled dataset exists.
14. **Forced termination has interval, not event, evidence.** `kill -9`, a crash or sudden power loss
    cannot execute a terminal callback. The next process header exposes a wall-clock/process gap and
    tail recovery reports partial bytes, but there is no exact in-stream boundary unless the writer
    itself failed first. Keep these intervals separate from ordinary active-time denominators.
15. **Stopped-controller actions are right-censored.** Pause, sleep, inactivity or shutdown closes the
    study observation session, but it does not forcibly abort an already running provider request.
    Its logged `action_cancelled` therefore means “outcome no longer observed”, not “provider failed”.

## What the exported data may contain

- event and affordance timing;
- app identity/category and content-free behavioural measurements;
- text length, language and shape;
- truncated one-way fingerprints;
- numerical sentence embeddings used for topic coherence;
- model probabilities, full numeric evidence decomposition and policy outcomes;
- stable interaction IDs, channel/rank, provider-turn completion/failure and in-situ answers;
- participant/study provenance, process boundaries and gap markers;
- the exact `IntentConfig.json` used for scoring.

It must not contain raw copied, selected or document text, screenshots, keystrokes, passwords, URLs,
file paths, document names, or the memory-only multi-copy content vault. Embeddings and behavioural
traces are personal data; content-minimised does not mean anonymous.

## Required 24-hour artefact test

Run this against the exact signed/notarised Release app that will be placed in the participant DMG,
not an Xcode Debug run.

1. Install the app in `/Applications`, complete the researcher-led Study setup and confirm:
   Study marker safe, updater absent/disabled, login launch enabled, Accessibility granted, recorder
   healthy, participant ID correct and event count increasing.
2. Produce copy, selection, scroll, focus and dwell events. Confirm the active trace grows on disk and
   every non-header JSONL line decodes.
3. Pause, continue using several apps for at least five minutes, then resume. The export must contain
   one pause and one resume boundary and no sensor/affordance events inside the paused interval
   (explicit sleep/wake/termination lifecycle records are allowed).
4. Summon the ticker; close it, let it time out, accept stale and fresh targets, dismiss a passive
   suggestion and complete/skip an in-situ prompt. Check action text, rank/channel/interaction linkage,
   `accepted → action_started → action_completed|action_failed|action_cancelled`, the correct usefulness-versus-
   relevance question, failure labels and realistic latencies.
   Include an exact repeated selection and two different selections in the same document; only the
   exact repeat may produce `repeat_selection`. Include a copy followed immediately by a DeepL switch,
   three different Safari-tab copies (must produce `collect_mode`), and mixed-language copies (must not
   manufacture cross-language `topic_coherence`).
5. Let the Mac enter `extended_inactivity`, then make the **first** keyboard-only action an immediate
   ⌘C without waiting for the 1 Hz check. Verify `active` precedes and the pending clipboard event
   follows it. Also type for >10 seconds without moving the mouse and confirm no reading dwell is emitted.
6. Put the Mac to sleep within ten seconds of a passive show/dismiss, wake by keyboard only, then copy
   and summon. Verify sleep/wake boundaries, no sleep-length dwell/focus event, reset exposure state and
   immediate post-wake capture.
7. Quit normally and relaunch. Force-kill once and verify the expected limitation that the app remains
   stopped; reopen manually and verify a new process/session header, a measurable wall-clock gap and
   any applicable tail-recovery audit (do not expect an invented terminal event). Separately reboot,
   log in and do not open the menu before producing events; login launch must create a new healthy
   process trace. Trigger a controlled writer failure separately if testing the durable
   `capture_failed` recovery marker.
8. Cross local midnight or use a controlled clock/test seam. Confirm safe daily rotation and that a
   failed replacement file never leaves a green recorder or loses the still-valid previous handle.
9. Export while recording remains active. Independently extract the ZIP and revalidate every
   manifest-listed filename, count, non-empty file and JSONL/config payload (including CRC via normal
   extraction); `IntentConfig.json` is mandatory and canonical; no temporary/raw-content file is present.
10. Observe at least 30 minutes active and 30 minutes inactive in Activity Monitor/Instruments. Record
   average CPU, wake-ups, Energy Impact and RSS; also inspect the main thread during AX reads.

## Acceptance thresholds

- no unexplained lifecycle gap in the exercised run; record the expected ≤33-second unsynchronized
  crash/power-loss exposure separately;
- zero sensor or affordance events during an explicit participant pause;
- recorder/error status always matches actual durable writes;
- every successful accept corresponds to a session that actually opened;
- every exercised accepted auto-action has one start and one technical completion/failure record;
- every prompt and outcome joins to exactly one interaction, channel and rank;
- every ZIP manifest entry exists and validates;
- no public update feed/key/framework in the Study app;
- reboot/login resumes without a menu action after Login Items approval;
- force-quit remains visibly unrecorded until manual restart; the next process header makes the
  interval measurable without claiming a synthetic terminal marker;
- idle average CPU below 0.5%, Energy Impact below 1.0 and RSS below 150 MB;
- no perceptible main-thread stall during summon or selection polling.

## Limits that code/build checks cannot prove

- macOS Login Items approval and relaunch behaviour of the signed app;
- Accessibility coverage in each participant application (Preview is required for the PDF stimulus;
  Acrobat remains unsupported by AX);
- real sleep/wake, midnight, clock-change and disk-full behaviour;
- energy/CPU/RSS on the participant hardware;
- final DMG signing, notarisation, Gatekeeper acceptance and manual distribution discipline.
- real usefulness, correctness, recall and calibration; the instrument records evidence for later
  analysis but cannot prove those properties itself.

Until those checks pass, the build is an **engineering pilot**, not the final participant artefact.

## Verification record

This section is updated only with observed results.

- [x] Mandatory Git preflight completed on `thesis`; staged diff was empty before hardening.
- [x] `scripts/release.sh` syntax checked and observed to reject `thesis` before building.
- [x] `git diff --check` after source integration; final documentation pass repeated on 2026-08-13.
- [x] Clean Debug build with signing disabled succeeded on 2026-08-13.
- [x] Clean Release build with signing disabled succeeded on 2026-08-13.
- [x] Built Release app inspected: `DragawayStudyBuild = true`, automatic checks false, no feed/key,
      no Sparkle file, linkage, unresolved symbol or target package reference.
- [x] All 29 Golden checks passed in both the Debug and optimized Release artefacts on 2026-08-13.
- [ ] Signed Release DMG 24-hour test completed using the matrix above.
