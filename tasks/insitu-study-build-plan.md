# In-situ study build — plan

**Branch:** `thesis` (merged with `main` @ v1.1.5 on 2026-08-08)
**Goal:** a build that can be installed on 8–12 participants' own Macs and left running for ~13 days,
collecting interpretable data about summon behaviour without noticeably costing battery or stability.
**Research context:** `~/Desktop/Obsidian/MasterThesis/FinalDoc/` — see `03_Baseline/Phase2_Design_and_Build_Plan.md`,
`05_Method/InSitu_Capture_Design.md`, `06_Design_Build/Build_Spec_InSitu.md`.

Every item below carries the reason it exists, so the dissertation's method chapter can cite this file.

---

## Design principles for this build

1. **Ship the interaction, freeze the intelligence.** Weights stay hand-tuned and constant for
   every participant. Personalisation is computed offline from the logs afterwards. Rationale: too few
   labels to learn from in 13 days, and a model that drifts mid-study makes early and late data
   incomparable.
2. **The participant never controls capture, only pause.** Default on; pause is a privacy act and is
   logged as an explicit gap. Rationale: participant-triggered recording would select out the quiet
   reader, who is the research object.
3. **Interpretability at analysis time, not capture time.** Anchor context to affordance events via a
   one-tap question; segment work from leisure via idle detection.
4. **Nothing in the study build may phone home or self-update.**

---

## Work items

### A · Make the ticker an instrument (the core blocker)

- [x] **A1 · Generalise `TaskResolver`** beyond translation.
  Today `AffordanceController.toggleTicker()` only builds a `suggestion` when
  `intentClass == .translation`; comprehension and discovery rows render with nothing to accept. Ship
  that and participants summon once, find it inert, and stop.
  - resolve comprehension → summarise / explain / key points, against the current AX selection, else clipboard
  - resolve discovery → compare / synthesise, against the recent clipboard set
  - keep the existing hash-freshness contract (a suggestion must never point at replaced content)
- [x] **A2 · Quiet-reader path.** When there is no selection and no clipboard, offer document-level
  actions resolved from the focused window. A serialized, bounded AX probe on summon reads, hashes and
  discards local text; accept re-reads and requires the exact same PID/document/hash/length before use.
  Neither read enters the recorder/export.
- [x] **A3 · Ticker rows show the action** they will run, not just the class and evidence.

### B · Instrumentation (without this there is no analysable data)

- [x] **B1 · Full evidence vector in the affordance log.** `b.contributions` is already computed for
  the ticker's evidence string; serialise feature id, raw strength, decayed value and the resulting
  per-class probability at every summon / shown / accepted / dismissed / ignored event.
  **Offline learning and the RQ1 ablation are impossible without this.**
- [x] **B2 · Participant ID + study mode.** Stamped into every trace header and every affordance log
  line. Set once at onboarding.
- [x] **B3 · Export bundle.** One menu item → zip of traces + affordance log + config to the Desktop.
  Manual return by the participant; nothing uploads.
- [x] **B4 · Researcher-led consent setup**, recording wording version and timestamp into the log.
  Consent is an organisational prerequisite and provenance record, not a technically enforced lock.

### C · Survive 13 days unattended (each of these can cost a whole participant)

- [x] **C1 · Disable the updater in the study build.** The thesis branch is off v1.1.3 and the public
  appcast now advertises v1.1.5 — an active updater would replace the research build with one that has
  no Intent pipeline at all, mid-study. Not-publishing is necessary but not sufficient.
- [x] **C2 · Monotonic timestamps.** Every event currently carries wall-clock
  `Date().timeIntervalSince1970`. Over 13 days an NTP correction can step it backwards, and D13 has the
  replayer *reject* regressions > 1 s — one clock correction could invalidate a participant's whole
  fortnight. Record `ProcessInfo.processInfo.systemUptime` alongside, order and decay by it, and mark
  boot boundaries as explicit session breaks.
- [x] **C3 · Restart survival.** Verify end-to-end that after a reboot, with no participant action, the
  engine starts, the recorder opens a file and the affordance surface arms. The app registers as a
  Login Item; this is deliberately not a crash/force-quit watchdog, so physical approval/reboot testing
  remains in F2 and abrupt process gaps are inferred between process headers after manual reopen.
- [x] **C4 · Status indicator** in the menu (`Recording · day 4 · 1,204 events`) so both participant
  and researcher can see it is alive.
- [x] **C5 · Daily trace rotation** to a timestamped `trace-YYYYMMDD-HHmmss-SSS.jsonl`. Bounds the blast radius of a corrupt
  file and makes per-day analysis trivial.
- [x] **C6 · Sleep/wake lifecycle implementation** — timers, global scroll monitor, file handle, AX trust.
  Physical verification remains part of F2.

### D · Energy (a tool that costs battery gets uninstalled)

- [x] **D1 · Timer tolerance** on all three sensor timers. Currently none is set, so macOS cannot
  coalesce 5 wake-ups/second and the CPU never reaches a deep idle state. Clipboard 0.1, dwell 0.1,
  selection 0.3. No effect on data — every event carries its own timestamp.
- [x] **D2 · AX off the main thread.** `AXUIElementCopyAttributeValue` is synchronous cross-process
  IPC with a 6 s default timeout, running on main. A busy focused app blocks the menu bar.
  Dedicated serial queue + `AXUIElementSetMessagingTimeout(0.5)`.
- [x] **D3 · AX adaptive backoff.** Unchanged selection hash → 1 s slows toward 3 s; reset on app
  switch, scroll or click. Reading is exactly the case where nothing changes for minutes.
- [x] **D4 · Idle detection + gating.** `CGEventSource.secondsSinceLastEventType` (permission-free).
  Mark ambiguous quiet time after 60 s, then suspend periodic polling only after five minutes; emit
  explicit `inactive` / `extended_inactivity` / `active` events. Three payoffs: cuts
  wake-ups roughly in half, supplies the work/leisure denominator the study needs, and closes the
  documented `dense_dwell` reading-vs-away-from-desk conflation.

### E · Make the study measurable

- [x] **E1 · In-situ prompt** after sampled affordance interactions: result *useful?* (after completed accepted action) or suggestion *relevant?* (dismiss/failure), then *intrusive?* /
  *what were you doing?* (reading-research / writing / email / admin / other). Non-blocking, skippable.
  The third question is what makes every affordance event self-interpreting.
- [x] **E2 · Summon onboarding.** Discoverability is risk 1 of the pivot — an unknown hotkey means a
  summon rate near zero and a study that measures nothing.
- [x] **E3 · Pause control** with logged gap markers. A known gap is data; a silent gap is corruption.

### F · Verification before distribution

- [x] **F1 · Golden checks still pass** (29/29 in both Debug and optimized Release, including resolver,
  durability, schema/lifecycle audit, FIFO, discovery-language, AutoRun revision binding and frozen
  deployment-config checks; 2026-08-13).
- [ ] **F2 · 24 h self-pilot.** Acceptance: Energy Impact < 1.0 idle, < 0.5 % average CPU idle,
  < 150 MB resident, no perceptible main-thread stall, reboot resumes capture, offline launch performs
  no update check.
- [ ] **F3 · The interpretability test.** From the exported data alone, can I tell what kind of work
  surrounded each affordance event? If not, the study cannot answer its questions.

---

## Sequence

1. C1, D1 first — minutes of work, each prevents total data loss or a battery complaint.
2. C2 next — it changes the event schema, so everything downstream should be built on top of it.
3. B1–B4 — the logging contract, before the features that write into it.
4. A1–A3 — the largest single piece.
5. D2–D4, C3–C6.
6. E1–E3.
7. F1–F3.

## Out of scope, deliberately

Online learning · per-context priors · LLM tie-break and phrasing · preference compiler · expanding the
passive whisper beyond translation. All add confounds or risk without adding measurable value in 13
days. Personalisation is analysed offline instead.

---

## Review — session 1 (2026-08-08)

### Merge
`main` (v1.1.5 + session sharing) merged into `thesis`. **No conflicts.** Two local uncommitted edits
were stashed first; the `shareBaseURL` one-liner was superseded by main's fuller version and dropped,
the `todo.md` website note was re-applied by hand on top of main's rewritten file.
Stash `stash@{0}` retained as a safety net — safe to drop.

### Built and verified

| Item | What changed |
|---|---|
| **C1** updater off in study builds | `UpdaterController` reads `StudyMode.isActive` once at init and passes `startingUpdater: false`; manual check also refuses. Held in a `let` so toggling study mode later cannot resurrect a scheduled check mid-deployment. |
| **C2** monotonic time | New `MonotonicClock`: wall clock clamped so it can only move forward. Backward steps > 1 s are recorded as `Discontinuity` values rather than silently swallowed. All four sensors now stamp with it. Chose clamped wall clock over `systemUptime` because uptime does not advance during sleep, which would stop evidence decaying overnight. |
| **D1** timer tolerance | 0.1 s on clipboard and dwell, 30 % on selection and activity. Lets macOS coalesce wake-ups so the CPU can reach deep idle. |
| **D2** AX off the main thread | `SelectionSensor` polls on a serial utility queue; `AXUIElementSetMessagingTimeout(0.5)` on every element. Publishing hops back to main. `pollInFlight` drops a tick rather than queueing behind a hung app. |
| **D3** AX adaptive backoff | 1 s → 3 s after ~10 unchanged polls; app switch, scroll, click or keypress resets to fast immediately. |
| **D4** idle detection + gating | New `ActivityMonitor`: `CGEventSource.secondsSinceLastEventType`, 60 s threshold. Emits a new `.activity` signal kind (segmentation metadata, deliberately produces no evidence) and suspends every periodic sensor while away. Idle costs zero timers — only the event-driven input monitor stays armed. |
| **C5** daily trace rotation | `TraceRecorder` rotates at the calendar-day boundary, checked per event so an idle machine spends no wake-up asking. This intermediate checkpoint used `v: 2`; the hardened export contract is now trace v4 / affordance v4. |
| **B1** evidence vector logged | `AffordanceController.evidenceSnapshot(at:)` writes every class probability, every contributing feature with its decayed value, and θ, on every summon/shown/accepted/dismissed/ignored. This is what lets the study ship with frozen weights and still derive per-user personalisation offline. |
| **B2** study identity | New `StudyMode`: participant id, consent version + timestamp, deployment start, `stampFields`. Stamped into trace headers and every affordance log line. |
| — | `IntentSensor` gained `suspend()`/`resume()` with default no-ops, so event-driven sensors need no implementation. |

**Verification.** Compile-verified in an isolated worktree (`scratchpad/wt-verify`) carrying all 13
touched files: **0 errors in any Intent file and in `UpdaterController`.** Golden checks not yet re-run
(blocked, see below).

### 🟡 Blocker — `main` does not compile (RESOLVED IN PRINCIPLE: the work exists, it is just uncommitted)

**Update after investigation.** The second worktree builds **cleanly, 0 errors**, with its uncommitted
work in place. So the session-sharing feature is finished — it was simply never committed. The fix is
bookkeeping, not engineering:

```bash
git -C ~/development/MacNotchAI-main-browser-image add -A
git -C ~/development/MacNotchAI-main-browser-image commit -m "feat: complete session sharing"
# then, on thesis:
git merge main
```

**Expect one merge conflict, in `AppDelegate.swift`.** Comparing the change regions directly:

| Branch | Hunks in `AppDelegate.swift` (main's line numbers) |
|---|---|
| `thesis` adds | 65, **447 (+54 lines)**, 1254, 1879 |
| uncommitted share work touches | 3, 112, 387, **432–446**, 506, 724, 746, 815 |

Thesis inserts the Intent Engine submenu at 447; the share work edits the menu code at 432–446 —
**directly adjacent**, which is where git will need help. Every other hunk pair is well separated.

*Caveat on how this was checked:* a full simulated merge was attempted in the sandbox, but
`git apply --3way` reported files as applied cleanly whose content demonstrably did not change
(`BackendConfig` gained nothing despite a "cleanly" report). **Do not trust that experiment's
per-file verdicts** — the hunk-overlap comparison above is the trustworthy evidence.

### The original finding, for the record

A clean build of `main` at `f71e7fd`, in a fresh worktree containing no thesis code at all, fails with
7 Swift errors — all in `MacNotchAI/Share/ShareController.swift`, referencing types that exist nowhere
in the repository: `ActiveShareRecord`, `ShareSessionID`, `ShareClient.Claim`.

Cause: the second worktree `~/development/MacNotchAI-main-browser-image` holds **three Share files that
were never committed** — `ActiveShareStore.swift`, `ShareImportPolicy.swift`, `ShareInvitation.swift` —
plus ~20 modified files. `main` was committed referencing work that only exists there.

Not touched, deliberately: it is in-flight product work in another worktree, and completing it needs
decisions this session should not make. **It blocks distributing any build, study or otherwise**, so it
has to be resolved before the deployment. With the three files copied in as a compile sandbox only, the
error count drops 7 → 2, and the remaining two need the uncommitted edits to `ShareClient.swift` and
`ShareBundle.swift` from the same worktree.

### Session 2 — A1–A3 (resolver generalised, quiet-reader path built)

**The constraint that shaped the design.** `accept()` verified `pasteboardMatches(candidateHash)` and
routed through `openSessionFromClipboard()`, so every suggestion required its object to be on the
pasteboard. Comprehension and discovery backed by a copy fit that unchanged; the quiet reader — no
clipboard, no selection — did not. A second accept route was needed.

| Item | What changed |
|---|---|
| **A1** resolver generalised | `TaskResolver.resolve(intentClass:probability:extractor:)` is now the single entry point and resolves all three classes. Comprehension → `summariseBullets`, discovery → `extractKeyPoints`, translation unchanged. `FeatureExtractor` gained `latestTextCandidate` (newest text copy of any language — distinct from `translationCandidate`, which tracks only foreign copies because foreignness *is* translation's evidence) and `distinctRecentCopies`. |
| **A2** quiet-reader path | `SuggestionTarget.accessibility` makes selection/document targets explicit. `DocumentReader` reads the focused object via AX in two stages — a serialized bounded `probe()` on summon (read → PID/document/hash/length snapshot → raw text **discarded**) and an exact `read()` revalidation at accept. Accept materialises locally through `DropMaterializer.materialize(.text:)` and calls `openSessionWithFiles`. **Deliberately not routed via the pasteboard**: writing there would destroy whatever the participant had copied. |
| **A3** every row actionable | `toggleTicker()` resolves all three rows instead of only translation. |
| — | Remaining `Date().timeIntervalSince1970` call sites in the affordance path moved to `MonotonicClock.now`. Accept logs a `target` field, and failures log `accept_failed` with a reason rather than failing silently. |

**Two decisions worth defending in the write-up.**

*Offering nothing beats offering something inert.* `resolve` returns nil when there is no readable
object, and `DocumentReader.probe()` requires ≥ 400 readable characters before a document action is
offered. A participant who summons, picks "Summarise", and gets nothing learns the channel is
decorative and stops summoning — which would leave the study measuring abandonment rather than the
responsibility-transfer claim.

*The summon is the consent event.* Reading the focused document does not breach the privacy invariant,
it applies D6's boundary: content enters a session only after an explicit yes. The asymmetry runs in
the thesis's favour — a passive system must watch continuously to catch this moment; a summoned system
is licensed to look exactly once, when asked. **The floor watches less than the ceiling.**

**Bounded multi-source handoff.** Discovery keeps up to three recent copied texts in a RAM-only,
90-second/18,000-character vault. A suggestion captures exact hash/time references and accept either
materialises that exact set or fails; pause/stop/failure clears it. Nothing from the vault enters the
trace/export. `collect_mode` counts three distinct copies even within one browser bundle; topic
coherence compares only same-language Apple embedding spaces.

### Session 3 — merge completed, first green build, AX coverage tooling

`origin/main` @ `5ac301a` ("harden sharing and multi-file sessions") merged into `thesis`. **One
conflict, exactly where the hunk analysis predicted it: `AppDelegate.swift`.** Purely additive —
thesis contributes the `#if DEBUG` Intent-engine handlers, main contributes `windowWillClose` for the
share windows. Both kept. Everything else auto-merged.

**BUILD SUCCEEDED, 0 Swift errors, exit 0.** First fully green build of this work.

**AX coverage tooling.** `DocumentReader.diagnose()` plus a debug menu item, *Intent Engine → Probe
Document Reader (2 s delay)*. It reports, for the frontmost app: verdict, readable character count,
and which strategy found the text (`focused element` vs `window walk`). The three failure modes look
identical from outside and are entirely different problems — "app exposes nothing", "document too
short", "no Accessibility grant" — and only the first is about the app.

Fixed while building it: `diagnose()` could never report TOO SHORT, because the length threshold was
applied inside the traversal. It now lives at the call sites — `probe()`/`read()` need "long enough to
act on", the diagnosis needs the raw number.

**Coverage is an empirical result, not a code property.** Spot-check Preview, Safari, Chrome, Obsidian,
Notes and one Office app before the pilot; click into the document first, so the focused-element route
is exercised rather than only the window walk. Record verdict + char count + strategy per app: it
determines **for what fraction of participants the quiet-reader path exists at all**, and belongs in
the limitations as a measurement.

### Session 4 — first AX coverage results, two defects found and fixed

**Measured coverage, first run (before the fixes below):**

| App | Result |
|---|---|
| Notes | ✅ works |
| Safari (long article) | ⚠️ TOO SHORT — 54 chars, via window walk |
| Obsidian | ❌ NO TEXT |
| Preview (PDF) | ❌ NO TEXT |
| Acrobat (PDF) | ❌ NO TEXT |
| Finder (PDF preview) | ❌ NO TEXT |

Three defects, all mine, all fixed:

1. **Longest node instead of concatenation.** A web article is hundreds of small
   `AXStaticText` nodes a dozen levels deep; 54 characters was its longest *single* paragraph node.
   `collectText` now walks the subtree and joins the leaves, bounded by node (6 000) and character
   (40 000) budgets rather than a depth cap of 4. Fragments under 12 characters are skipped so
   toolbars do not masquerade as documents.
2. **Electron ships a stub AX tree.** Obsidian, VS Code, Slack and friends disable accessibility for
   performance. `AXManualAccessibility` (plus `AXEnhancedUserInterface`) is now set on the application
   element before any read; harmless where unrecognised.
3. **No focused element meant an immediate bail-out.** Someone who is only *reading* usually has
   nothing focused — no caret, no text field. That is the quiet reader's normal state, not an edge
   case. There is now a fallback to the application's focused window.

**Separate defect — the menu appeared to deactivate until restart.** `NSAlert.runModal()` fired on a
2 s delay while this app was in the *background* puts the process into a modal run loop the user can
neither see nor dismiss. Probe results now append to `IntentTraces/ax-probe-results.txt` with audible
feedback (two beeps = readable, one = not) and a second menu item opens the file. Better for the task
anyway: probe six apps in a row, then read them together.

**Coverage after the fixes (measured 2026-08-10):**

| App | Before | After | Route |
|---|---|---|---|
| Notes | ✅ | ✅ | focused element |
| Safari (long article) | 54 chars | **24 415** ✅ | window walk |
| Preview (PDF) | 0 | **32 335** ✅ | window walk |
| Obsidian (Electron) | 0 | 0 → retry added, **re-test pending** | — |
| Acrobat (PDF) | 0 | 0 ❌ | — |

**The PDF result rescues the study design.** Task 2 is a PDF reading task and the quiet-reader case
that motivated the whole pivot occurred inside it; had PDFs stayed unreadable, the stimulus would have
had to change. Note *which* fix did it: not the concatenation but the focused-window fallback. A person
who is only reading has nothing focused, so the bail-out sat precisely in the core case. Onboarding
instruction: **open PDFs in Preview, not Acrobat.**

**Electron retry (fix 4).** The `AXManualAccessibility` request was useless as written: Chromium builds
the tree *asynchronously*, so the read always preceded the answer. Now: request, read, and on the first
attempt per application wait 400 ms and read once more. Deliberately lazy rather than applied on every
app switch — forcing every Electron app on a participant's machine into full accessibility mode for
thirteen days would tax their work to serve ours. Re-test Obsidian twice in a row.

**Acrobat is written off deliberately.** It renders independently and exposes essentially nothing via
AX. No fix worth the time, and none needed while Preview works. Documented limitation.

**Coverage for the write-up:** browsers, native applications and PDFs-in-Preview cover the large
majority of real reading. The boundary runs at Electron applications and Acrobat, and it can now be
stated precisely rather than vaguely — measured, not asserted.

### Session 5 — B3 export, B4 consent, C4 status line

**Obsidian now reads.** The Electron retry works, confirming the async-tree diagnosis. Final coverage:
Notes ✅ · Safari 24 415 ✅ · Preview 32 335 ✅ · Obsidian ✅ · Acrobat ❌ (written off).

| Item | What was built |
|---|---|
| **B3** export | `StudyExporter.exportToDesktop()` stages traces + affordance log + `IntentConfig.json` + a manifest, zips via `NSFileCoordinator(.forUploading)`, drops it on the Desktop and reveals it in Finder. |
| **B4** consent | `StudyConsentView` — a one-time sheet run at the onboarding meeting. Records participant id, consent version and timestamp, then arms the instrument (engine on, affordances live, recorder started). |
| **C4** status | Menu line: `● Recording · P03 · day 4 · 1 204 events`, or a `⚠︎ NOT recording` warning. Plus *Export Study Data…* and *Stop Taking Part…*. |

**Manual export is a design decision, not a shortcut.** Nothing uploads. It buys a consent story with
no asterisk ("nothing leaves your machine unless you send it" is simply true), removes any
cross-border transfer analysis, and creates a real withdrawal point — consent on day 1 is not consent
on day 13, and a participant who changes their mind just never sends the file.

**The manifest is written for the participant, not the researcher.** Every file is listed with what it
holds, in plain language, alongside an explicit list of what is *not* in the bundle. Someone cannot
meaningfully consent to sending something they cannot inspect.

**Both consent text and manifest state that the data is NOT anonymous.** This is stronger than the
approved proposal, which promises data "anonymised using participant IDs". Content-minimised
behavioural data with partially invertible embeddings and hash prefixes is pseudonymous, not
anonymous, and the implementation refuses a claim it cannot support. Carried into the methodology
chapter as deviation P-L rather than smoothed over — **still needs a supervisor decision on whether it
requires an ethics amendment.**

Also fixed here: the two remaining `NSAlert.runModal()` call sites now `NSApp.activate` first, so they
cannot repeat the background-modal freeze.

### Session 6 — E1 in-situ prompt

Three one-tap questions on the same non-activating panel as the whisper: after a completed accepted
action, **was the AI result useful?**; after dismissal/failure, **was the suggestion relevant?**; then
**intrusive? → what were you doing?** One question at a time — a three-part form is a task, a single
yes/no that replaces itself is a reflex, and sampling in situ only earns its cost if it catches the
reaction before it becomes a considered account.

The first two measure the **wanted-versus-intrusive** distinction that replaced the leading "would you
have used it?" — the thing the reframed research question turns on. The third is what makes every
affordance event self-interpreting: without it, an event inside a fortnight of continuous capture
cannot be told apart from an hour of video watching, and summon rates lose their denominator.

**The sampling rate is the whole design problem, and it is a study-validity issue rather than a UX
one.** Asking after every interaction makes the *asking* the intrusion, and the measure then destroys
what it measures. Hence: at most 5 per day, never within 15 minutes of the last, and only after the
participant actually engaged (completed/failed accepted action or dismiss). An *ignored* whisper never triggers a prompt —
someone who just showed you they were busy is the last person to interrupt, which is the mistake this
whole thesis is about.

**Skips and timeouts are recorded, not dropped.** Unanswered prompts fade after 30 s and log
`skipped=timeout`; explicit dismissals log `skipped=skipped`; partial answers record how far the
participant got (`answered_stage`). Which moments people decline to rate is itself data, and treating
non-answers as missing-at-random would bias the intrusiveness measure toward whoever happened to be at
their desk.

Prompts only appear when `StudyMode.isActive`, so ordinary users never see them. This sample is
missing-not-at-random and must not be used alone to claim unbiased recall/AUC/calibration.

### Session 7 — E2 summon hint, E3 pause control

**E3 pause.** `IntentEngine.isPaused`, persisted, wired to a menu toggle. Pausing writes an explicit
`paused` marker to the trace, suspends every sensor and tears down the affordance surface; resuming
writes `resumed` with the elapsed duration. **A known gap is data; a silent gap is indistinguishable
from a crash** and would corrupt any rate computed over elapsed time.

*The interaction that mattered:* the idle automatism and the manual pause use the same
`suspend()`/`resume()` mechanism, so without a guard the first keystroke after a pause would have
resumed everything — the control would have appeared to work and quietly not. `activity.onChange` now
returns early while paused.

*And the design point worth restating in the methodology:* capture is ON by default and the
participant may switch it off, never the reverse. Same control, opposite default, entirely different
dataset — an opt-in recorder would capture only what participants consider interesting and would
systematically exclude the quiet reader.

**E2 summon hint.** A card on the whisper surface — the place suggestions actually appear, rather than
a settings pane nobody revisits — shown once after consent, plus a menu item to re-show it on request.

**Deliberately no nudging.** The obvious feature is a reminder for participants who have gone quiet,
and it is the wrong instinct: summon rate is a primary outcome, so a reminder would measure the
reminder. If people do not summon, that is the pivot's discoverability risk (§6.5, risk 1) showing up
as a *result* — a finding about the design, not a defect in the data. The in-person onboarding meeting
does the teaching; the software does not chase.

### Verification status — read this before trusting any build result

The integrated thesis worktree reached explicit `BUILD SUCCEEDED` for Debug and Release with signing
disabled on 2026-08-13. All 29 Golden checks passed in both built artefacts, and the Release bundle
contained no Sparkle linkage/framework/feed/key. The detailed bundle-isolation results are recorded in
`docs/thesis/24H_RECORDING_HARDENING.md`; the signed-DMG physical 24-hour matrix remains F2/F3.

### Still to do

- **F2** signed/notarised DMG 24 h self-pilot · **F3** interpretability test
- **AX coverage spot-check** — `DocumentReader` is best-effort across apps. Try it in Preview, Safari,
  Chrome, Obsidian, Notes and one Electron app before the pilot, and record which ones yield text.
