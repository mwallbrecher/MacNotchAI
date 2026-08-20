# Computational Intent Pipeline — Architecture Specification

**Thesis:** *From Prompting to Intent Recognition: Designing Context-Aware AI Affordances in
Operating-System Workflows* (Kingston University, CI7801)
**Author:** Moritz Wallbrecher · **Host app:** Dragaway (macOS) · **Branch:** `thesis` only
**Status:** living document — this is the architecture deliverable (Objective 2) and the
implementation contract for all `Thesis-Component:` work.

> North star: *infer the need, before it is prompted.* The system observes OS-level interaction
> signals, infers user intent, and surfaces the right AI affordance at the point of intent —
> proactively, on-device, without ever getting in the way.

---

## 1 · Problem decomposition

| # | Sub-problem | Layer |
|---|---|---|
| 1 | **Sensing** — which OS signals are observable, at what permission/CPU cost | L1 |
| 2 | **Representation** — turning a raw event stream into computable evidence | L2 |
| 3 | **Inference** — log-linear intent estimate `P̂(intent class | evidence)`; empirical calibration is evaluated later | L3 (+L3b) |
| 4 | **Decision & resolution** — *when* to surface *which* concrete action, *how phrased* | L4 |
| 5 | **Learning** — per-user improvement without initial training data | L5 |

**Hard constraint A — silence bias (the Clippy problem).** In the overwhelming majority of
moments the user has *no* assistable intent. The base rate makes even a high-precision
classifier annoying unless the architecture is structurally biased toward silence. This is
enforced mathematically (§5, prior term) and by policy (§7).

**Hard constraint B — local sensing + explainability.** No raw content enters the study sensor,
scorer or exported instrumentation, and every suggestion must be *explainable*. This rules out
black-box models in the inference path and motivates the log-linear scorer (§5), whose additive
score decomposition **is** the explanation. This boundary does not describe accepted AI actions:
after an explicit accept, the exact verified source is sent through the provider configured in
Dragaway, just as for an ordinary user-initiated action.

---

## 2 · Pipeline overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  L1  SENSORS          Clipboard · AppFocus · Dwell/Scroll · AX-     │
│      (event stream)   Selection/Target Context · FileActivity (M2) │
├─────────────────────────────────────────────────────────────────────┤
│  L2  FEATURES         detectors: ForeignLanguage, ReReading,       │
│      (evidence)       CollectMode, CopySwitchPaste, DenseDwell …   │
├─────────────────────────────────────────────────────────────────────┤
│  L3  SCORER           log-linear Bayes score per intent class      │
│      (P(intent|E))    + personalised weights & priors              │
├─────────────────────────────────────────────────────────────────────┤
│  L3b DISAMBIGUATOR    planned, not present in this Study build     │
├─────────────────────────────────────────────────────────────────────┤
│  L4  POLICY+RESOLVER  utility threshold θ(tier), cooldowns, quiet  │
│                       contexts; intent → concrete AIAction+phrase  │
├─────────────────────────────────────────────────────────────────────┤
│  L5  AFFORDANCE       whisper pill (passive) + summon ticker       │
│      + FEEDBACK       (active); accept/dismiss/ignore → learning   │
└─────────────────────────────────────────────────────────────────────┘
```

Each layer is independently replaceable (the modularity claim of the proposal). Reused
Dragaway assets: pasteboard polling pattern (`ClipboardHistoryStore`), content heuristics
(`FileSignals`), decayed usage scores (`ActionFrecency`), the 36-action catalog (`AIAction`),
the notch pill (`OverlayViewModel` stages), the provider layer incl. Ollama.

Target intent classes (proposal Objective 2): **Translation/Transformation** (primary MVP),
**Comprehension**, **Discovery/Cross-Reference**.

---

## 3 · L1 — Sensors

| Sensor | API | Permission | Emits |
|---|---|---|---|
| Clipboard | `NSPasteboard.general.changeCount` polling (0.5 s) | none | content-derived scalars (§4) |
| App focus | `NSWorkspace.didActivateApplicationNotification` | none | bundle id, category, dwell-in-previous |
| Scroll | global `NSEvent` monitor `.scrollWheel` | none (pointer events are ungated) | scroll bursts: net Δ, direction changes |
| Mouse dwell | 2 Hz poll of `NSEvent.mouseLocation`; stationary spans containing key-down activity are suppressed | none | stationary periods ≥ 10 s |
| Selection / target context | Per-frontmost-app `AXObserver` plus a slow compatibility poll; bounded `AXSelectedText`, `AXDocument`, `AXStringForRange`/`AXValue` reads | **Accessibility (required before Study capture)** | selected-text scalars; hashed document identity; coarse focus role, target language/read strategy and caret/visible-range buckets; no path/raw text crosses the bus |
| Object boundaries | pasteboard `changeCount`; AX focused-window/title notifications | Accessibility only for AX boundary | v5 content-free `pasteboard` / `accessibility_target` scope plus optional focused bundle id; no replacement type/content/hash or AX object metadata |
| File activity | FSEvents / `NSMetadataQuery` | folder TCC | new/changed files — **M2** |

**Permission stance.** The *released* app (main branch) requests zero permissions as of
v1.1.3 and stays that way. The manually distributed research prototype (this branch) requires
**Accessibility before recording can start** and explains the exact reads during researcher-led
setup. While capture is active and not paused, it may transiently inspect the focused role,
selection, document path or window title and a bounded target-document range to derive the fields
above. An eligible local `.docx` is size-preflighted and may be transiently imported before only a
bounded sample is classified. Raw text, paths and titles are discarded before publication. Accepting
a suggestion is a separate, explicit boundary: the exact source is re-read and sent through the
provider the participant configured.
`CGEventTap` (named in the proposal) is deliberately avoided: scroll/dwell work through ungated
`NSEvent` APIs. AX observers are primary; a 14-second poll (±1-second tolerance) and interaction
triggers cover apps that do not implement notifications. AX support remains application-specific.
Secure or ambiguously classified text fields are a hard no-read boundary, not merely fields whose
returned values happen to be ignored. This applies both to continuous `SelectionSensor` capture and
to the explicit `DocumentReader` used for Summon/accept-time resolution; its bounded tree walk rejects
an uncertain subtree before reading that node's value or children.

---

## 4 · Event model & the privacy invariant

Sensors emit `SignalEvent` values (Codable, JSONL-serialisable). **The invariant: raw content
never crosses the bus.** Content-derived scalars are computed *at capture time inside the
sensor* and the content is discarded:

- clipboard text → content class, char/word count, top language + confidence,
  `isForeignLanguage`, shape (`prose|code|table|list|question|fragment`), `hasURL`,
  SHA-256 hash prefix (re-copy/dedup detection without content), source app
- sensitive pasteboards are **skipped entirely as clipboard-content signals** via the shared
  `PasteboardPrivacy` gate
  (concealed · `com.apple.is-sensitive` · transient · auto-generated — the same list the
  clipboard-history feature uses, so the two clipboard paths cannot drift; auto-generated
  is also semantic hygiene: a programmatic write is not a user copy, hence not a content signal).
  Every ownership revision first emits the same content-free `pasteboard` boundary; sensitive or
  unsupported replacements emit nothing else. That timing-only record retracts the prior object's
  evidence/UI identically in live capture and replay without revealing replacement type, source,
  hash or content.
- Accessibility target context → bundle id, hashed document identity, allowlisted extension,
  allowlisted focus-role category and tri-state editability, bounded-sample language/confidence and character
  count, read strategy, and rounded 0…20 caret/visible-range buckets. `range_metadata` explicitly
  preserves progress when an app exposes ranges but no readable text; it carries zero sample
  characters and no language, so it cannot become translation evidence. The sensor may use a
  `.docx` path or bounded AX text transiently, but the schema cannot represent the path, filename,
  title, text, AX description/identifier or absolute offsets. Direct `.docx` import is restricted to
  non-symlink, downloaded files on local volumes (≤8 MiB compressed, preflighted to ≤32 MiB expanded
  and ≤2 MiB `word/document.xml`) and rate-limited to one attempt per document/minute. Sampling prefers
  a target-local visible/near-caret `AXStringForRange`, then a reported-small text-role `AXValue`, with
  eligible DOCX import only as the final text fallback. Derived results are cached by hashed document
  identity and modification time; raw document content is not cached. Queued observations are bound
  to lifecycle generation, PID and a same-PID observation revision; any focus/selection/value/layout/
  scroll change makes an older completion unpublishable.
- Accessibility window/title changes emit a content-free `accessibility_target` boundary before the
  replacement read. IntentEngine first flushes a pending copy under the old segment; feature state then
  advances one replayable document revision and retracts the old target even if the new read lacks a
  `docID` or language. This closes the 0.5-second Word A→B attribution race for apps that support those
  AX notifications; unsupported same-app transitions remain a measured conservative limitation.
- every live event carries a process-uptime ordering/decay time `t` and a separate wall time. The two
  values come from one clock stamp; explicit discontinuities and session/boot UUIDs make wall-clock
  steps and process resets analysable. All within-session inference uses `t`; the replayer rejects an
  unexplained regression and accepts a typed `uptime_reset` boundary.

The `SignalBus` keeps a ring buffer (window 120 s / cap 600 events, trimmed against the
*newest event's* time, not wall clock) for windowed feature extraction; older data exists only
as aggregates.

**Honest classification of what remains:** the bus carries no raw content, but what it does
carry — content hashes, sentence embeddings, app identities, timing — is **content-minimised
behavioural data, not anonymous data**. Embeddings are partially invertible, hashes support
membership tests ("was exactly this text copied?"), and the event stream itself profiles work
behaviour. Consequences: traces stay on-device, count as personal data under UK GDPR (consent +
retention rules, M5), and anonymisation is deliberately **not** claimed anywhere in this design.
Data minimisation is architecture; anonymity would be an overclaim.

---

## 5 · L3 — Scoring: log-linear Bayes

We want `P(c | E)` for each intent class `c`. Naive Bayes in log-odds form turns
multiplication into addition:

```
S_c  =  log P(c)/(1−P(c))  +  Σ_i  w_i · f_i · e^−(t−t_i)/τ_i
        └─────prior────────┘   └──evidence, decayed──────────┘
P(c|E) = σ(S_c) = 1/(1+e^−S_c)
```

- **Weights are log-odds contribution parameters.** Their initial values are theory/formative-data
  motivated and synthetically regression-tested; without empirical likelihood estimation they must
  not be reported as measured likelihood ratios.
- **The prior enforces silence.** With `P(c) ≈ 0.02`, every hypothesis starts at ≈ **−3.9**;
  evidence must contribute ~4–5 points before anything can surface.
- **Decay is analytic and lazy**: `e^−(t−t_i)/τ` is a pure function of *read time* — scores are
  computed on new events or on demand. **No timers tick for scoring.**
- **Explainability is built in**: each feature's contribution `w_i·f_i·decay` is an additive
  summand; the "why this suggestion?" popover is a printout of the score decomposition.

**Worked example (Translation), as implemented.** Prior −3.9; foreign-language clipboard
(w 2.2 × confidence 0.9, decayed ≈ +1.9); switch toward a translator within 10 s (+3.0)
→ S ≈ +1.0 → P ≈ 0.73 → show (θ=0.70). Foreign copy alone: P ≈ 0.12; translator switch alone:
P ≈ 0.29 → **silence** either way. Earliness (suggesting on the copy alone) is **earned through
personal evidence** (§9), never assumed. These percentages are model estimates, not yet calibrated
probabilities. Translation is the only passive class; noisier comprehension/discovery families remain
summon-only until evaluated on real labelled data.

A second, target-relative route covers bilingual participants: a fresh text copy followed by an
editable AX target whose confidently detected language differs emits
`copy_target_language_mismatch`. This comparison deliberately does not ask whether the copied
language belongs to the participant's repertoire. It requires a real destination transition: a
different application, a known source `docID` changing inside the same application, or a recorded
same-process document/window boundary between copy and target. The exact clipboard fingerprint is
promoted as the translation target and, for the supported `en`/`de`/`fr`/`es` actions, the target
document's language selects the action. Evidence strength is the lower of the two language confidences:
at full strength, its composite weight 5.0 raises the fresh default model from the 2% prior to
approximately 75%; at the typical 0.95/0.96 confidence in the Golden scenario it reaches approximately
70%, crossing the balanced threshold without a translator-app switch. The one evidence row is bound
to that concrete clipboard object and target: an ownership replacement, conclusive same-language/
read-only result or target boundary retracts it, while missing/unknown AX data preserves an already
valid unchanged-target join but can neither create evidence nor act as a negative. Same-language
targets, same-document copies and stale copies remain silent.

**Initial parameters** (from the formative-study taxonomy; provenance column required —
every weight cites the observation that motivated it):

| Param | Initial | Notes |
|---|---|---|
| Prior per class | logit(0.02) ≈ −3.9 | + per-context personal offsets (§9) |
| τ clipboard evidence | 60 s | a copy from 5 min ago says nothing |
| τ dwell/scroll evidence | 180 s | reading state decays slower |
| Feature window | 90–120 s | matches ring buffer |
| Weight clamp | ±4 normally; ±6 only for `copy_target_language_mismatch` | ordinary atomic signals cannot decide alone; the target mismatch is an explicitly composite copy+editable-destination observation |

---

## 6 · L3b — Planned, not implemented in this Study build

The current classifier and suggestion phrases are deterministic. There is no uncertainty-band
provider call, no LLM vote, no metadata/content-tier toggle, and no preference compiler in the
deployed instrument. Sensing, feature extraction, scoring and resolution remain local and
content-minimised. Only accepting a concrete AI action crosses the separate provider boundary: the
exact fingerprint- or AX-snapshot-verified copied/selected/document source is materialised and sent
through the provider configured in Dragaway. This user-initiated provider traffic is not written to
the thesis trace or export; only its content-free start/completion/failure lifecycle is logged.

An LLM disambiguator or generated phrasing remains a future design option and must not be described
as an experimental factor or privacy control of this build.

---

## 7 · L4 — Decision policy

Show iff expected utility exceeds interruption cost: `P·V > (1−P)·C`. Since C is high, the
threshold is high. **Sensitivity tiers set C — they shift the exposure threshold θ only,
never the score.** With frozen parameters, P̂ stays mechanically comparable across users and tiers;
whether it is empirically calibrated is a study question, not an implementation claim.

| Tier | θ_show | Rate limit | Semantics |
|---|---|---|---|
| Lazy | 0.85 | 3/h | "only when near-certain" |
| Balanced (default) | 0.70 | 6/h | |
| Aggressive | 0.55 | 12/h | "rather one miss than a missed need" |

Guardrails: per-class dismiss cooldown (10 min) · ignore = auto-fade ~8 s, logged as weak
negative · "do not suggest again" hard mutes per (class × app) · **quiet contexts**: fullscreen,
presentation, **screen sharing**, secure input — never speak. (Known confound to report:
aggressive users generate more feedback → learn faster.)

**Two channels, one scorer.**
- *Passive channel:* unsolicited whisper — gated by θ(tier). M3 defaults: accept = click or
  **⌥⏎** (Carbon hotkey, registered only while the whisper is visible), dismiss = ×,
  no reaction = 8 s auto-fade (logged as `ignored`, weak negative).
- *Active channel (summon ticker):* **⌃⌥⌘I** (or the debug menu) shows the current top-3
  intents with their current model estimates — **no threshold**; a solicited suggestion cannot
  annoy by definition. The reusable non-activating panel carries a presentation generation, so an
  asynchronous close/fade completion may never order out a later summon. Hotkeys become
  user-configurable with the M4 user-control surface.

The ticker doubles as a measurement instrument: every summon is an observable **help-seeking
moment**, not ground truth for one of the three intent classes. A summon while the passive channel
stayed silent is a useful candidate missed-need case for later labelling, not by itself a false
negative. Ranking and the percentage display can influence the selected row and must be treated as
part of the intervention. The candidate buffer also gives faded suggestions a recovery path.

**Resolver:** intent class + verified candidate metadata → deterministic mapping into the
`AIAction` catalog. For translation, a supported confident editable-target language (`en/de/fr/es`)
outranks the participant-language preference; otherwise English then another declared supported
participant language is chosen while avoiding the detected source language. Comprehension chooses
selection → current matching pasteboard → document, and discovery chooses a bounded multi-copy vault
→ pasteboard → document. There is no embedding or `ActionFrecency` fine-ranking in `TaskResolver`.
Output: `(AIAction, target object, fixed suggestion phrase)`.

**Accepted-action handoff:** the app delegate explicitly installs a weak session opener before the
intent engine starts. Accept re-verifies and materialises the exact target, asks that opener for the
new overlay `sessionRevision`, and independently checks that the live session owns the expected file.
An Accessibility-backed re-read first proves that the focused role/subrole is non-secure; unknown is a
hard failure, including every subtree considered by the bounded document walk. Only after all checks
is `accepted` durable and the revision-bound one-shot latch allowed to invoke the selected `AIAction`
through the ordinary chip/provider path. Runtime delegate discovery and time-only payloads are not
part of this boundary.

---

## 8 · L2 — Feature detectors per class (M2)

| Class | Detector | Core signal |
|---|---|---|
| Translation/Transformation | `foreign_language_clip` | NLLanguageRecognizer: clipboard lang ∉ user languages, 40–2000 chars |
| | `copy_target_language_mismatch` | fresh text copy language ≠ confidently detected editable AX target language, independent of user-language repertoire |
| | `copy_then_translator_switch` | copy → translator/dictionary app or tab within 10 s |
| | `format_mismatch` | clipboard shape (code/table) vs. target-app capability |
| Comprehension | `visible_range_revisit` | same `(app, docID)` AX visible-range progress returns to an earlier coarse bucket after moving away |
| | `re_reading` | labelled fallback: ≥3 scroll direction changes / 60 s when AX range coverage is absent |
| | `dense_dwell` | mouse-quiet + no app switch + document focused ≥ N s |
| | `repeat_selection` | repeated AX selections under the same `(app, docID)` identity |
| Discovery/Cross-Ref | `collect_mode` | ≥3 copies / 90 s from ≥2 sources |
| | `topic_coherence` | pairwise cosine of snippet embeddings > 0.55 ⇒ one research thread |
| | `copy_to_search` *(deferred)* | coarse AX focus role is now recorded, but this affordance remains outside the pilot scope |
| | `entity_overlap` *(deferred)* | NLTagger NER: same entities in clipboard and open document |

Embedding backbone: start with Apple `NLEmbedding` (zero deps); the interface is cut so
MiniLM-L6 (CoreML, 384-dim, ~90 MB) is a drop-in. Decide empirically when `topic_coherence`
discriminates too weakly on real traces. Embeddings are computed at capture and cached by
content hash (10–40 ms on Apple silicon).

---

## 9 · L5 — Learning & user control

**The ownership split** (resolves "wouldn't this be learned anyway?"):

```
S_c = Prior_c + Σ w_i f_i
      └─PREFERENCE─┘ └─EVIDENCE─┘
      owned by USER   owned by LEARNER
```

- **Evidence weights `w_i`** ("how reliable is this signal?") belong to the learner. Online
  logistic update after each outcome, in log-odds space:
  `w_i ← w_i + η·(y − P)·f_i` with η = 0.08; accept y=1, dismiss y=0, ignore y=0 at η/4;
  clamp ±4; feedback half-life 14 days (frecency pattern). Plus per-(class × app-context)
  **prior offsets** — the mechanism behind *earned earliness*: repeated accepts in a context
  raise its personal prior until earlier, weaker evidence suffices. Measurable as
  time-to-affordance over sessions.
- **Priors + thresholds per class** ("how often do I *want* to be asked?") belong to the user.
  Explicit control is not redundant with learning: (1) learning needs exposures — low prior +
  lazy tier = cold-start deadlock, a statement breaks it instantly; (2) aspiration ≠ observed
  behaviour; (3) it *is* the "meaningful user control" requirement, concretely.

**`IntentConfig`** — single source of truth, every value provenance-tagged
(`default | onboarding | user-statement | learned`):
`{ tier, prior_offsets[class], cooldowns[class], mutes[(class,app)] }`

**Preference compiler.** Natural-language statement ("ask me about translations more often") →
user-selected LLM receives *only that sentence* + the parameter schema → strict JSON of deltas.
Three safety layers: **whitelist** (unknown keys dropped) · **clamp** (prior offsets ±1.5 ≈
odds ×4.5 max) · **preview diff + undo** before anything applies. Config changes are logged
events (usage of language control is itself a finding). Onboarding uses the same compiler on
2–3 workflow questions, provenance `onboarding`.

---

## 10 · Telemetry, traces, replay — the study is part of the architecture

- **Log everything, including below threshold**: every event writes
  `(t, feature vector, all class scores, decision, outcome?, in-situ rating?)` —
  pseudonymised, on-device, consent-gated. RQ1 ("which signal combinations suffice?") becomes
  an **offline ablation**: re-score logged traces with feature subsets → precision/recall/AUC
  per combination, no new sessions needed.
- **Traces** are JSONL files of `SignalEvent`s (current schema v5; schema §4). The exporter retains
  strict read compatibility with v4 traces, but `accessibilityContext` and `contextBoundary` are legal
  only in v5. The
  formative observation sessions are encoded as traces too — the interview keyframes literally
  become regression tests.
- **Replay harness**: feed a trace through the pipeline deterministically (possible because
  all logic uses event time, §4). Golden traces = unit tests for intent detection; every
  threshold experiment is exactly reproducible.
- **Read-only (capture-only) mode** (`intentReadOnly`): sensors + scorer + trace recorder run,
  the affordance surface is fully suppressed (no whisper, no summon hotkey, no affordance log).
  THE mode for **Phase 1 formative observation** — the signals must be captured without the
  system perturbing the behaviour under study — and for any later data collection. Toggling it
  live attaches/detaches the affordance layer without interrupting a recording.
- **Current Study build:** one intent-mediated condition with accepted/dismissed/ignored plus linked
  provider-turn started/completed/failed/cancelled records and bounded in-situ prompts (result useful
  or suggestion relevant, intrusive, work context). It does **not** implement the planned
  chat/drag/intent condition switcher or experimental task timing; those remain required for a
  comparative RQ2 study.
- **Participant erasure:** the Study menu offers only a relative 5-minute-to-4-hour slider.
  `StudyTraceRedactor` closes capture, persists a crash-recoverable request, removes the physical trace
  and affordance suffix plus complete interactions crossing its cutoff, validates every replacement,
  emits a content-free receipt and opens a fresh segment when recording was active. A pending request
  blocks capture/export until the same idempotent operation completes; prior exports and filesystem
  backups remain outside this local transaction.

---

## 11 · Milestones & acceptance

| M | Scope | Accept when |
|---|---|---|
| **M1** | SignalBus, Clipboard/AppFocus/Dwell sensors, trace recorder + replayer, engine flag + debug menu | a recorded real session replays with identical event stream; zero permissions used |
| **M2** | AX sensor (optional in debug use, required and disclosed in Study deployments), feature detectors, scorer + `IntentConfig`, weights tuned on own traces | golden smoke checks (debug menu → Run Golden Checks) all pass; "why" decomposition available |
| **M3** | whisper affordance + policy + resolver (Translation e2e) + summon ticker. **Passive channel fires for translation only** — comprehension/discovery stay ticker-only until evaluated on real traces | translation scenario works end-to-end passively and via summon |
| **M4** | online learning, context priors, preference compiler, onboarding, LLM disambiguator/phrasing | preference statement changes behaviour with preview+undo |
| **M5** | study instrumentation, in-situ prompts, researcher-led consent provenance, export | pilot produces an analysable feasibility/RQ1-style dataset; comparative RQ2 condition tooling remains separate |

**Component ↔ `Thesis-Component:` trailer map:** `infrastructure` (workflow/docs) ·
`signal-capture` (L1, traces, replay) · `intent-scoring` (L2/L3/L3b) · `affordance-ui` (L4/L5
surfaces) · `personalization` (learning, priors) · `user-control` (tiers, compiler, onboarding)
· `study-instrumentation` (telemetry, study modes).

## 12 · Open decisions

1. **Embedding backbone** — NLEmbedding vs. MiniLM-CoreML; decide on real-trace discrimination
   of `topic_coherence` (§8).
2. **Ticker hotkey & exact whisper visuals** — decide in M3 with the UI work.
