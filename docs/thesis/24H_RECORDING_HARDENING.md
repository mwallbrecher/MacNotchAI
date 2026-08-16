# 24-hour study-recording hardening

**Branch:** `thesis`

**Date:** 2026-08-14

**Purpose:** turn the A1–A3, B1–B4, C1–C6, D1–D4 and E1–E3 prototype into a
fail-visible instrument suitable for a 24-hour engineering pilot before participant deployment.

This note is the handoff contract for the exact study artefact. It separates properties proved by
code/build checks from behaviour that still has to be exercised on the signed DMG and a real Mac.

## Agreed scope

The owner confirmed four study-design boundaries during review:

1. Consent is handled with the researcher before recording. Researcher-led setup records an
   affirmative checkbox plus wording version and timestamp for provenance. There is no process-wide
   first-launch lock and a later wording-version bump does not retroactively stop an already active
   deployment.
2. Normal AI-action traffic follows the provider configured in Dragaway. It is not part of the thesis
   recorder or exported study bundle and is outside this instrumentation review.
3. While recording is active and not paused, the AX sensor may briefly read a selection, document
   path or window title and bounded target-document range to derive language, focus-role and coarse
   reading-progress fields. An eligible local `.docx` may be size-preflighted and transiently imported
   before only a bounded text sample is classified. After explicit suggestion acceptance, the resolver
   may re-read an exact fingerprinted pasteboard source and `DocumentReader` may re-read an exact AX
   selection/document snapshot. Raw content, paths and titles must never enter a trace, affordance log
   or study export.
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
- The public product Clipboard History recorder runs in a Study build exactly as it does in the
  product, on the participant's own preference. It is a product feature rather than a study
  instrument, so it needs no separate justification in the consent text — describing it there would
  wrongly imply the study collects it. Isolation is structural on three independent levels: the
  intent pipeline holds no reference to `ClipboardHistoryStore` (`ClipboardSensor` observes the
  pasteboard independently and applies the same `PasteboardPrivacy` gate), the two stores live in
  different Application Support directories, and the exporter both restricts itself to `.jsonl` under
  `IntentTraces/` and fails via `verifyStaging` if the staged set ever differs from the manifest.
- Forcing it off was the larger risk and was reverted: `ClipboardHistoryStore.isEnabled` defaults to
  true, so every participant would otherwise have run a configuration the shipping product never
  produces — and one that alters copy behaviour, which is the behaviour under study.

This protects both directions: a Study build cannot consume a public Main update, and the repository's
normal release path cannot advertise a Study build to public clients.

### Relaunch and login recovery

- Study setup registers the signed main app through `SMAppService.mainApp`; the menu reports whether
  login launch is enabled or still requires approval.
- Researcher-led setup shows live Accessibility and Login Item readiness. It may request/open the
  relevant System Settings panes. Accessibility is a hard Start gate; Launch at Login is displayed and
  registered/repaired during setup but remains a separately reported readiness state rather than a
  capture gate.
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

- New trace files use schema **v5**. Each file starts with a typed header containing app version, local
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
  trace-v5/affordance-v4 semantic schema while retaining trace-v4 read compatibility. The new
  `accessibilityContext` payload is valid only in a v5 trace. Export canonical-decodes/re-encodes typed
  rows (so unknown `rawText`, path or
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

### Exact Accessibility-context export contract

Only a trace-v5 `accessibilityContext` payload may carry the derived AX observation below. Optional
values are omitted when unavailable; the exporter canonical-decodes and re-encodes the payload, so no
unrecognised AX field can pass through.

Trace v5 also has one content-free `contextBoundary` record so live inference and replay invalidate
the same mutable objects. Its exact payload is `{scope: "pasteboard", app: nil}` for every general-
pasteboard ownership revision, or `{scope: "accessibility_target", app: <optional bundle id>}` for a
conclusive same-process AX focused-window/title transition. It contains no replacement class, source,
hash, role, document identity, title, path or content-derived scalar. A sensitive/unsupported
pasteboard therefore contributes only boundary timing; no `clipboard` payload follows it. Context
boundaries are illegal in legacy trace v4.

| JSON field | Exact exported domain and meaning |
|---|---|
| `app` | Optional focused-app bundle identifier (valid bundle-ID syntax, at most 200 characters). |
| `docID` | Optional 16-character lowercase hexadecimal prefix of the one-way document-identity hash; never a path or title. |
| `documentExtension` | Optional lowercase allowlisted extension: `txt`, `md`, `markdown`, `rtf`, `rtfd`, `pdf`, `doc`, `docx`, `odt`, `pages`, `csv`, `tsv`, `xls`, `xlsx`, `numbers`, `ppt`, `pptx`, `key`, `html` or `htm`; it is valid only with `docID`. |
| `focusedRole` | Exactly one of `text_field`, `text_area`, `search_field`, `web_area`, `document` or `other`. |
| `editable` | Tri-state: `true` means AX explicitly reports an editable target; `false` means AX explicitly reports it non-editable; omitted (`nil`) means unsupported, timed out or otherwise unknown. Unknown must never be analysed as read-only or used as positive destination-mismatch evidence. |
| `language` | Optional two-letter lowercase ASCII language code for the bounded sample. It is present or absent together with `langConfidence`. |
| `langConfidence` | Optional finite `0...1` confidence paired with `language`. |
| `sampleCharCount` | Required integer `0...4000`: characters actually classified, never the document's reported total length. |
| `readStrategy` | Exactly one of `document_file`, `visible_range`, `value`, `range_metadata` or `none`. |
| `caretBucket` | Optional coarse document-progress bucket `0...20`. |
| `visibleStartBucket`, `visibleEndBucket` | Both absent or both `0...20`, with start no greater than end. Absolute AX offsets never cross the sensor boundary. |
| `trigger` | Exactly one of `initial`, `focus`, `selection`, `value`, `layout`, `scroll` or `fallback`. |

The strategy values have distinct semantic invariants:

- `document_file` means an eligible local `.docx` was transiently imported. It requires `docID`,
  `documentExtension: "docx"` and `sampleCharCount > 0`.
- `visible_range` means a bounded `AXStringForRange` sample (at most 4,000 characters) succeeded;
  `sampleCharCount > 0`.
- `value` means the focused role was `text_field`, `text_area` or `search_field` and
  `AXNumberOfCharacters` first reported a non-negative total no greater than 12,000. Only then may the
  whole `AXValue` cross IPC; classification still receives at most 4,000 characters.
- `range_metadata` means no text sample succeeded but at least one coarse caret/visible-range bucket
  did. It has no language/confidence and `sampleCharCount == 0`.
- `none` means neither text nor progress metadata was available. It has no language/confidence,
  `sampleCharCount == 0` and no buckets.

`initial` covers the first binding; `focus` covers app/focused-element/focused-window changes and the
mouse-up compatibility trigger; `selection`, `value` and `layout` identify the corresponding
`AXObserver` notifications; `scroll` is the global scroll compatibility trigger; and `fallback` is
the 14-second timer (one-second tolerance). Trigger-only duplicates are deliberately suppressed by
the context signature, so trigger coverage must be measured among materially changed rows rather than
as a count of all callbacks.

The `.docx` path is deliberately narrower than the extension field: the file must be a regular,
non-symlink file on a local volume, not an iCloud/ubiquitous item, and at most 8 MiB compressed. ZIP64,
encrypted or malformed archives are rejected before import; total declared expansion is capped at
32 MiB and `word/document.xml` at 2 MiB. The cache contains only derived language scalars under
`docID + mtime`; a full import attempt is limited to once per document per 60 seconds. Target-local
`AXStringForRange` is attempted first, a reported-small text-role `AXValue` second, and the eligible
DOCX import only as the final text fallback. A secure or ambiguously classified role produces neither
`selection` nor `accessibilityContext` rows and performs no document/window/range/value reads. The same
role/subrole-first, fail-closed rule protects the explicit `DocumentReader` used by Summon and
accept-time verification; its bounded window walk skips every secure or ambiguously classified
subtree before reading values or children. Every queued sensor result is bound to its lifecycle
generation, source PID and same-PID observation revision, then checked against the current frontmost
PID before publication. Focus, selection, value, layout and scroll observations advance that revision,
so a late result cannot be published for a newer object or content state inside the same application
either.

### Participant-controlled recent-trace erasure

- The Study menu exposes one deliberately narrow control: a relative-duration slider from **5 minutes
  through 4 hours in 5-minute steps**. It has no calendar/time picker, free-text prompt, file lookup,
  app/action filter or provider call.
- Confirming the action first stops and synchronizes both live writers. Trace files retain only the
  physical prefix before the first event in the selected interval. The affordance log also removes
  every earlier row belonging to an interaction that crosses that boundary, so no partial lifecycle
  remains. Recovery/failure records inside the interval are removed with the same transaction.
- Before changing a source file, the redactor atomically persists `redaction-pending.json`. Every
  input and proposed replacement is checked with the exporter's typed validator, replacements are
  atomic and verified, and launch/retry completes the same idempotent request before capture or export
  can resume. If validation or disk I/O fails, recording and export remain stopped and the request
  stays visible for retry.
- Completion appends exactly one content-free `redaction-log.jsonl` receipt with the interval and
  participant/consent provenance, but no reason, prompt, file/app/action selector, deleted payload or
  deletion count. If the study is still active, inference state is reset and recording continues in a
  fresh segment; a participant pause remains a pause.
- Erasure governs the active on-device study cohort and all **future** exports from it. It cannot
  rewrite ZIPs already exported to Desktop or bytes retained independently by APFS snapshots, Time
  Machine or other backups; those copies must be removed separately under the study retention
  protocol.

### Participant-facing menu boundary

- During an active study, `Intent Engine (Thesis)` contains only the visible capture status and
  recovery actions plus **Pause/Resume Recording**, **Erase Recent Traces**, **Show Summon Hint**,
  **Export Study Data** and **Stop Taking Part**. These are the controls a distributed participant may
  need without researcher assistance.
- When no study is active, researcher setup and all manual engine, trace, replay, score, ticker,
  Accessibility sensor, language, Golden-check, AX-probe and config tools live one level below
  **Debugging**. They no longer compete visually with participant controls.
- The submenu is absent during an active deployment. This is a safety boundary, not cosmetic hiding:
  operator mutators must not permit one capture layer to be stopped independently and create an
  unmarked data gap. After withdrawal, **Export Existing Study Data** and **Erase Recent Traces** stay
  directly available while a new **Study Setup** remains inside **Debugging**.

### Typed confirmation for destructive participant actions

- **Erase Recent Traces** retains the bounded duration slider but keeps its red destructive button
  disabled until the participant enters the exact, case-sensitive text `CONFIRM`. Its warning states
  that all data in the selected interval will be lost and ends with: “That is okay, but be aware that
  this can’t be undone.”
- **Stop Taking Part** uses the same typed gate before it can write the withdrawal boundary or change
  study state. Its copy does **not** claim that existing data is deleted: it says recording stops,
  participation/contribution ends, and retained data remains local unless the participant chooses to
  send it. It preserves the same final irreversible-action sentence.
- Cancel and ordinary window close only dismiss either confirmation. No writer, deployment or stored
  data state changes until the enabled destructive button is explicitly pressed.

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
- Accessibility revocation removes the AX sensor, writes
  `accessibility_unavailable`, flushes it and shows a warning. A restored grant writes
  `accessibility_restored`. Content-bearing AX calls run on a serial utility queue with 0.5-second
  element timeouts, a one-request limit and lifecycle generations that discard late results. The
  small observer-registration calls remain on the main run loop but use a separate 0.15-second
  timeout, remember unsupported notifications and retry transient failures. Per-application
  `AXObserver` notifications are the primary trigger; priority-coalesced interaction triggers and a
  14-second poll (≤15 seconds including tolerance) cover applications that do not publish useful
  notifications. Range-only clients emit explicit `range_metadata` progress without pretending that
  a language sample succeeded. Local `.docx` reads are ZIP-preflighted against compressed/expanded
  limits and rate-limited per document so autosave storms cannot repeatedly invoke the Office importer.
- Mouse-stationary intervals containing a key-down are suppressed rather than classified as reading
  dwell. No key value is observed or stored; this uses only the permission-free system inactivity
  duration.

### Action and affordance-label integrity

- Translation may resolve either a foreign-language copy or a fresh copy whose language differs from
  a confidently detected editable target document. The latter remains valid for bilingual users and
  selects the target document language when a matching built-in action exists. Comprehension resolves
  the narrowest current object in this order: AX selection, fresh matching pasteboard text, then a
  focused document snapshot. Both translation routes require the exact fresh pasteboard fingerprint.
  Discovery uses an exact two-or-more-source RAM snapshot when possible, else a fresh pasteboard
  object or current document.
- The discovery vault is memory-only, lives for at most 90 seconds, holds at most three entries,
  bounds each entry to 6,000 characters and the total to 18,000, and clears on pause/stop/failure.
  Accept resolves the exact references; expiry/replacement fails rather than substituting content.
- AX selection/document targets record only PID, app, scope, content hash, character count and a
  hashed document identity. Accept re-reads off-main and requires the same app/PID, document, length
  and hash before materialising local content for the visible Dragaway session.
- Every ticker row logs its concrete action, actionability, one-based rank and shared interaction ID.
  `summon`/`ticker_closed` are explicit rank-0 surface records. The ticker closes with a logged reason
  on user close, displacement, stop or its 30-second timeout. Repeated `⌃⌥⌘I` presentation is
  generation-bound: an older asynchronous fade completion cannot order out a newer summoned ticker,
  and hiding an already ordered-out panel does not create another delayed teardown.
- `accepted` is written only after the overlay session revision changes, reaches a session stage and
  owns the expected file; an `.error` stage is not success. The deferred auto-run latch is bound to
  that exact session revision and is cleared on stop/failure, so it cannot run an old suggestion on a
  replacement file. Accept also snapshots the overlay revision at click time and rechecks it after
  asynchronous AX/vault resolution, preventing a delayed suggestion from replacing a newer explicit
  drop/session. `AppDelegate` explicitly installs the weak, revision-returning session opener
  before capture starts; accept never depends on a runtime `NSApp.delegate` cast. Stale/replaced/expired
  targets, failed materialisation, unavailable openers and failed revision/session verification are
  distinct content-free `accept_failed` reasons. The export validator shares the complete categorical
  allowlist and its Golden fixture proves every supported reason exports while unknown reasons fail.
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
| A2 | Background AX context is observer-first, bounded and content-minimised; explicit action sources are independently revalidated at accept. Raw probe text/path/title is discarded. | Code/build; coverage remains app-specific. |
| A3 | All ticker rows expose the action or state that no verifiable source exists. | Code/build and manual ticker check. |
| B1 | Every affordance record carries all class scores and the full unthresholded evidence decomposition. | Typed v4 affordance schema/export validator. |
| B2 | Participant, study, consent, process and session identity are stamped at source. | trace-v5/affordance-v4 validators reject missing provenance; legacy trace v4 remains readable. |
| B3 | Manual Desktop ZIP contains validated traces, log, exact config and manifest; nothing uploads. | Deterministic schema seam plus manual ZIP inspection. |
| B4 | Researcher-led setup records consent wording version/time. Consent remains an organisational protocol, as agreed. | Setup/state and exported provenance. |
| C1 | Study app has no package/framework/feed/key path to Sparkle; public release script rejects non-`main` and Study marker. | Built-bundle inspection; repeat on signed DMG. |
| C2 | Ordering/decay uses uptime; wall time, clock steps and process sessions remain explicit. | v5 schema and live-stamp Golden check. |
| C3 | Active Study relaunch starts the recorder before sensors only when required AX context is ready (or remains fully paused); otherwise it fails closed. `SMAppService.mainApp` handles login launch and reports approval. It deliberately does not watchdog a crash/quit. | Code/build; signed-DMG reboot and force-quit tests still mandatory. |
| C4 | Menu distinguishes recording, paused and incomplete states and shows current-process successful event writes. | Manual status test. |
| C5 | New trace per process and local-day transition bounds corruption and keeps a day key. | Code plus controlled-midnight test. |
| C6 | Sleep/wake closes sources, clears stale evidence and re-evaluates AX before resuming. | Code; real sleep/wake test still mandatory. |
| D1 | All recurring study timers have tolerance, including 30-second writer sync timers. | Source/build inspection. |
| D2 | Selection and target-context content IPC runs on one off-main serial queue with per-element timeout and lifecycle-generation rejection; short observer registration remains on the main run loop with a tighter timeout. | Source/build and Instruments stall check. |
| D3 | Debounced AXObserver notifications are primary; a 14-second compatibility poll (±1-second tolerance) plus scroll/click triggers covers unsupported apps. | Source/build and energy trace. |
| D4 | 60-second quiet marker plus five-minute polling gate preserves quiet reading better than treating silence as absence. | Activity markers plus physical energy test. |
| E1 | Linked, skippable, bounded usefulness-or-relevance/intrusiveness/context prompts, plus technical provider-turn outcomes. | v4 records and manual prompt matrix. |
| E2 | One-time/on-demand summon hint plus checked Carbon hotkey registration. | Golden/build plus hotkey-conflict test. |
| E3 | Persisted pause with ordered durable boundaries and no sensor/affordance capture inside the gap. | Suspended-start Golden check plus 5-minute pause test. |

## Why the 24-hour pilot is promising

The build now records enough independent structure to evaluate the thesis without raw content:

- translation has foreign-text, source app, copy→translator-switch and editable target-language
  mismatch evidence that remains meaningful for bilingual participants;
- comprehension has AX visible-range revisits, labelled scroll fallback, app-correct dwell and exact
  repeated-selection evidence;
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
   notifications, ranges or text. The fallback still records explicit `readStrategy: none` coverage,
   but cannot infer target language or progress. Highly dynamic pages can change length/hash between
   show and accept, producing honest `accept_failed` rows but fewer successful quiet-reader actions.
   Report read-strategy/language/range coverage and trigger distribution among changed rows per app
   and scope rather than treating missing AX support as negative behaviour. Because unchanged reads
   are deduplicated, the trace cannot by itself measure notification support or callback frequency.
2. **Very long quiet reading.** At five minutes without input, polling is gated to save battery. The
   interval is explicitly marked, but selection/dwell detail after that boundary is absent until
   keyboard or pointer input resumes. Do not equate `inactive` or `extended_inactivity` with absence.
3. **Clipboard and same-app transition timing.** The sensor polls at 0.5 seconds, reconciles a pending
   change on app switch, and flushes it synchronously before a supported AX window/title boundary.
   This orders Word A copy → Word B transition when the application emits those notifications; apps
   that emit neither retain a conservative same-app false-negative risk. Every pasteboard revision has
   a content-free boundary, so privacy-gated/unsupported replacements retract live and replay state
   without revealing their type/content. The physical test must cover rapid copy→DeepL, Word A→B and
   visible-suggestion replacement paths and verify trace/affordance order.
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
11. **Progress remains coarse.** When an app exposes a document identity and visible range, re-reading
    is tied to rounded 0…20 document-progress buckets; otherwise the detector keeps the older
    app-scoped scroll heuristic as labelled fallback. Dwell excludes observed typing but still cannot
    prove the participant was reading.
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
16. **Participant erasure creates explicit missing data.** A `redaction-log.jsonl` receipt identifies
    the removed interval without retaining its contents or a reason. Analyse that interval as
    participant-redacted missingness, not inactivity. Already exported ZIPs and independent filesystem
    backups are outside the in-app transaction.

## What the exported data may contain

- event and affordance timing;
- content-free pasteboard/accessibility-target ownership boundaries (scope and optional focused app
  only), including boundary timing for sensitive/unsupported pasteboard replacements;
- app identity/category and content-free behavioural measurements;
- text length, language and shape;
- the exact derived AX fields listed above: optional app/document identity and extension, coarse focus
  role and tri-state editability, optional sampled language/confidence, bounded sample count, read
  strategy, optional `0...20` progress buckets and trigger;
- truncated one-way fingerprints;
- numerical sentence embeddings used for topic coherence;
- model probabilities, full numeric evidence decomposition and policy outcomes;
- stable interaction IDs, channel/rank, provider-turn completion/failure and in-situ answers;
- participant/study provenance, process boundaries and gap markers;
- participant-requested redaction interval timing and provenance, without deleted contents or reason;
- the exact `IntentConfig.json` used for scoring.

It must not contain raw copied, selected or document text, screenshots, keystrokes, passwords, URLs,
file paths, document names, or the memory-only multi-copy content vault. Embeddings and behavioural
traces are personal data; content-minimised does not mean anonymous.

## Required 24-hour artefact test

Run this against the exact signed/notarised Release app that will be placed in the participant DMG,
not an Xcode Debug run.

1. Install the app in `/Applications` and complete researcher-led setup. Confirm the Study marker is
   safe, the updater is absent/disabled, Accessibility reads **Granted**, the recorder is healthy, the
   participant ID is correct and the event count increases. Inspect the active trace header, an
   affordance session boundary and the export README/manifest provenance: all must carry consent
   version **4** and the same non-zero `consentAcceptedAt` timestamp from the frozen deployment (and,
   after step 9, the redaction receipt must match it).
2. Exercise every Login Item status on a disposable installation or controlled status seam and verify
   the exact setup label/action pair: **Enabled**/no repair action, **Approval required**/**Open
   Settings…**, **Not registered**/**Register…**, and **Unavailable**/**Check…**. Only Enabled supports
   the reboot-survival claim; the other states stay visibly unready even though they do not silently
   redefine the AX capture gate.
3. Verify every fail-closed route into active capture. Revoke Accessibility and relaunch an active,
   unpaused deployment: no trace/sensor capture may start, the menu must say incomplete/Required and an
   explicit repair plus Retry must be necessary. Relaunch while participant-paused: it must remain
   fully paused and event-free without AX; Resume must stay paused when AX is missing. Retry while
   unpaused must remain stopped without AX. Finally erase recent traces while active, remove AX before
   restart, and confirm the post-erasure restart remains stopped until permission is restored and Retry
   succeeds.
4. Produce materially changing AX contexts for each scheduling route. In a notifying app, observe
   `initial`, `focus` and each supported observer-derived `selection`, `value` and `layout`; cause a
   range-changing scroll and observe `scroll`; in an app without useful notifications, wait through
   the 14-second fallback interval (up to one additional second of timer tolerance) and observe
   `fallback`. Unchanged contexts may emit no row because
   signature deduplication intentionally ignores `trigger`. During a deliberately slow AX read, switch
   rapidly app A → B → A and confirm no late A/B result is published under the wrong app/PID or after
   its generation became stale. Repeat without changing PID while selection/value/layout/scroll events
   arrive during the read; the earlier completion must fail its observation-revision check. Switch
   rapidly between two windows/tabs in one application and verify the content-free AX boundary appears
   before the replacement context and prevents the earlier context from being relabelled.
5. Exercise every `readStrategy`. A bounded text-bearing range must produce `visible_range`; an eligible
   small text role may produce `value` only when AX reports total length ≤12,000. A client exposing
   progress ranges but no text sample must produce `range_metadata` with at least one `0...20` bucket,
   zero sample count and no language/confidence. A client exposing neither text nor progress must
   produce `none` with zero sample count, no language/confidence and no buckets. Confirm every changed
   row contains only the exact fields/domains documented above and no raw text, path, filename, title,
   AX description/identifier or absolute character offset. Where a DOCX exposes both a local AX range
   and a readable file, verify the target-local range wins; only loss of the range and bounded-value
   paths may reach the DOCX fallback.
6. Exercise the `.docx` boundary with controlled fixtures. A valid regular, non-symlink, non-iCloud
   local file ≤8 MiB with bounded ZIP expansion must be eligible for `document_file`. Separate files
   that are >8 MiB, iCloud/ubiquitous, symlinks, malformed/encrypted/ZIP64, declare >32 MiB aggregate
   expansion, or declare `word/document.xml` >2 MiB must never use `document_file`; their earlier AX
   range/value path may still produce `visible_range`, `value`, `range_metadata` or `none`. Change the
   eligible document's mtime and generate an observer storm; Instruments/file access must show at most
   one full import attempt for its `docID` in 60 seconds while target-local sampling remains responsive.
7. Focus a secure text field, change its contents, select text, scroll and wait through a fallback
   interval. Confirm the trace receives neither a `selection` row nor an `accessibilityContext` row for
   that field. While it remains focused, invoke Summon and attempt a fresh/stale accepted action; no
   selected-text/document suggestion or provider request may be produced from that target. Repeat with
   a secure descendant inside a walkable window. The source/helper audit must separately confirm both
   `SelectionSensor` and `DocumentReader` check role/subrole before any window, document, range, value,
   selected-text or child read and skip the uncertain subtree; absence of a row alone cannot prove call
   order.
8. Pause, continue using several apps for at least five minutes, then resume. The export must contain
   one pause and one resume boundary and no sensor/affordance events inside the paused interval
   (explicit sleep/wake/termination lifecycle records are allowed).
9. On a disposable pilot cohort, exercise **Erase Recent Traces** at 5 minutes while active. Confirm
   that older trace rows remain, the physical suffix is absent, an interaction crossing the cutoff is
   removed in full, one content-free receipt exists and capture continues in a new segment. Repeat at
   4 hours while paused and confirm it remains paused; also confirm post-withdrawal erasure works and
   that export is unavailable while a deliberately retained pending request exists. Independently
   remove any ZIP exported before the test because the app cannot rewrite that copy.
10. Summon the ticker; close it, let it time out, accept stale and fresh targets, dismiss a passive
    suggestion and complete/skip an in-situ prompt. Check action text, rank/channel/interaction linkage,
    failure labels, realistic latencies and the correct usefulness-versus-relevance question. Monitor
    the configured provider (or use a request-counting provider seam): passive display, summon and row
    resolution must make **zero** provider requests before acceptance; one fresh click must first
    produce the durable sequence `accepted → action_started`, then exactly one provider request and one
    terminal `action_completed|action_failed|action_cancelled` row.
11. Include an exact repeated selection and two different selections in the same document; only the
    exact repeat may produce `repeat_selection`. Include a copy followed immediately by a DeepL switch,
    three different Safari-tab copies (must produce `collect_mode`), and mixed-language copies (must not
    manufacture cross-language `topic_coherence`). In Word, copy German text into an editable English
    `.docx` while participant languages include German and English: require
    `copy_target_language_mismatch`, Translate to English and accept-time verification of that exact
    clipboard object. A same-document copy/selection followed by its own document context must remain
    silent; moving focus to a different editable document may establish the required destination
    transition. Repeat with `editable` unknown, German→German and a copy older than 15 seconds; none may
    emit the mismatch. While a mismatch suggestion is visible, replace the general pasteboard in turn
    with unrelated text, a URL, an image, files, a sensitive/concealed item and an otherwise unsupported
    representation. Every change must first emit exactly one content-free `pasteboard` boundary,
    retract the old mismatch and cancel its pasteboard-bound surface; sensitive/unsupported replacements
    must emit no `clipboard` row. Re-copying valid text may create one fresh evidence row; identical AX
    callbacks must not refresh or stack it. For same-app Word A→B, verify a pending copy is emitted before
    the `accessibility_target` boundary; copy made after that boundary must remain bound to B and silent
    when B's context arrives. A boundary followed by missing `docID`/language must still retract A.
12. For visible-range re-reading, record A, then a materially different B in the same `(app, docID)` (start or
    end differs by at least two `0...20` buckets), then the exact A again through a navigation-capable
    `scroll`, `layout`, `focus` or `fallback` trigger. The return must be at least four seconds after the
    original A and at least one second after B. Confirm exactly one `visible_range_revisit`; an unchanged
    duplicate A, a one-bucket movement, a quicker return or a `selection`/`value` trigger must not add it.
    Repeat selection and range histories in two apps that expose the same title-derived `docID`; neither
    feature may cross the application boundary.
13. Let the Mac enter `extended_inactivity`, then make the **first** keyboard-only action an immediate
    ⌘C without waiting for the 1 Hz check. Verify `active` precedes and the pending clipboard event
    follows it. Also type for >10 seconds without moving the mouse and confirm no reading dwell is emitted.
14. Put the Mac to sleep within ten seconds of a passive show/dismiss, wake by keyboard only, then copy
    and summon. Verify sleep/wake boundaries, no sleep-length dwell/focus event, reset exposure state and
    immediate post-wake capture.
15. Quit normally and relaunch. Force-kill once and verify the expected limitation that the app remains
    stopped; reopen manually and verify a new process/session header, a measurable wall-clock gap and
    any applicable tail-recovery audit (do not expect an invented terminal event). Separately reboot,
    log in and do not open the menu before producing events; approved login launch must create a new
    healthy process trace. Trigger a controlled writer failure separately if testing the durable
    `capture_failed` recovery marker.
16. Cross local midnight or use a controlled clock/test seam. Confirm safe daily rotation and that a
    failed replacement file never leaves a green recorder or loses the still-valid previous handle.
17. Export while recording remains active. Independently extract the ZIP and revalidate every
    manifest-listed filename, count, non-empty file and JSONL/config payload (including CRC via normal
    extraction); `IntentConfig.json` is mandatory and canonical; `redaction-log.jsonl` is present after
    step 9; no pending, temporary or raw-content file is present.
18. Observe at least 30 minutes active and 30 minutes inactive in Activity Monitor/Instruments. Record
    average CPU, wake-ups, Energy Impact and RSS; also inspect the main thread during AX reads.

## Acceptance thresholds

- no unexplained lifecycle gap in the exercised run; record the expected ≤33-second unsynchronized
  crash/power-loss exposure separately;
- zero sensor or affordance events during an explicit participant pause;
- recorder/error status always matches actual durable writes;
- every successful accept corresponds to a session that actually opened;
- every exercised accepted auto-action has one start and one technical completion/failure record;
- every prompt and outcome joins to exactly one interaction, channel and rank;
- erased suffix events and complete crossing interactions are absent, with one valid receipt per request;
- every ZIP manifest entry exists and validates;
- no public update feed/key/framework in the Study app;
- reboot/login resumes without a menu action after Login Items approval;
- force-quit remains visibly unrecorded until manual restart; the next process header makes the
  interval measurable without claiming a synthetic terminal marker;
- idle average CPU below 0.5%, Energy Impact below 1.0 and RSS below 150 MB;
- no perceptible main-thread stall during summon, observer storms or fallback AX polling.

## Limits that code/build checks cannot prove

- macOS Login Items approval and relaunch behaviour of the signed app;
- Accessibility notification/range/language coverage in Word, Pages, Notes, Chrome and Preview
  (Acrobat may remain unsupported by AX), including actual `.docx` path exposure and import;
- real sleep/wake, midnight, clock-change and disk-full behaviour;
- energy/CPU/RSS on the participant hardware;
- final DMG signing, notarisation, Gatekeeper acceptance and manual distribution discipline;
- physical removal from previously exported ZIPs, APFS snapshots, Time Machine or other backups;
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
- [x] Recent-trace erasure implementation passed all 30 Golden checks in clean, signing-disabled
      Debug and optimized Release artefacts on 2026-08-14.
- [x] Participant/operator menu matrix inspected in source; the menu-cleanup delta passed clean,
      signing-disabled Debug and optimized Release builds plus 30/30 checks on 2026-08-14.
- [x] Typed `CONFIRM` gates and truthful Erase/Withdrawal copy inspected in source; the delta passed
      clean, signing-disabled Debug and optimized Release builds plus 30/30 checks on 2026-08-14.
- [x] Manual-summon re-presentation and accepted-action session handoff fixes passed a fresh
      signing-disabled Debug build, a clean optimized Release build and 32/32 built Golden checks on
      2026-08-14. Real repeated-hotkey plus pasteboard/AX acceptance smoke remains owner-pending.
- [ ] Signed Release DMG 24-hour test completed using the matrix above.
