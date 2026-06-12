# Meeting Coach — Implementation Plan

Live coaching during meetings (the essential magic), plus a private post-meeting coach report. Supersedes the feasibility draft of this doc; decisions carried forward:

- **Live-first.** The live layer ships in v1, not as a follow-up.
- **The coach report is private.** It lives in `meta.json` and renders in-app only — never written into `notes.md` / `transcript.md` mirrors, never included in copy/export of notes. Feedback is about *you*, not the meeting.
- Verified 2026-06-12 against 26 real transcripts: Parakeet emits filler words ("um" ×114 / "uh" ×18 in one 24k-word meeting), with some normalisation — filler rate is presented as a relative/trend signal, not an absolute count.

Companion plans: `meeting-context.md` (calendar metadata → preset auto-suggestion, scheduled end time), `meeting-screenshots.md`.

## 1. Architecture at a glance

```
                     (~100×/s)                       (1 Hz)
recorder.onLevel ──┐                          ┌──> nudge rules ──> notch island (coach mode)
micRecorder.onLevel ┴─> MeetingCoachSignals ──┤
transcriptLines (8s-ish utterances) ──────────┘    (10 s cadence, shared loop)
                                              └──> checklist watcher (LLM) ──> island / live pane

post-pass: transcript.json ──> finaliseMetrics (code) ──> meta.coach.metrics
           metrics + transcript + rubric ──> coach report (LLM) ──> meta.coach.report
```

Three load-bearing facts about the existing live pipeline make this cheap:

1. **The me/them split needs no diarization.** Mic and system are physically separate tracks. `MeetingSession.State.recording(elapsed:micLevel:sysLevel:)` (`MeetingSession.swift:23`) already carries both levels; the raw callbacks (`recorder.onLevel` / `micRecorder.onLevel`, `MeetingSession.swift:254,278`) fire ~100×/s and stash into `lastMicLevel`/`lastSystemLevel`. The coach signal engine taps those same callbacks.
2. **A live LLM cadence already exists.** `MeetingNotesAccumulator` ticks every 10 s, single-flight, consuming `transcriptLines` via a `consumedLineCount` cursor (`MeetingNotesAccumulator.swift:101,82`). The checklist watcher is a second consumer in the same loop, same patterns (claim-batch-up-front, empty-reply-is-expected, parse-only-the-contract).
3. **The overlay surface is shared.** The coach's live UI is the meeting-time mode of the notch island (`notch-island-hud.md`), which inherits `HUDPanel`'s proven window mechanics (`UI/HUDController.swift:191` — non-activating, cross-Space, status-bar level). No coach-specific panel exists.

## 2. Module structure

```
Sources/Dictator/Meetings/Coach/
  MeetingCoachEngine.swift        # Owns signals + nudges + checklist state for ONE recording.
                                  #   @MainActor @Observable; constructed by MeetingSession alongside
                                  #   notesAccumulator; exposed the same way (session.coachEngine).
  MeetingCoachSignals.swift       # Deterministic signal computation: VAD from levels, windowed
                                  #   talk ratio, monologue timer, overlaps, pace/filler/question
                                  #   counters from transcriptLines. Pure logic, no UI, no LLM.
  MeetingCoachNudger.swift        # Rule table: signals -> at most one active CoachNudge.
                                  #   Thresholds, sustain, cooldown, expiry. Pure logic.
  MeetingCoachChecklist.swift     # Checklist state + the LLM watcher pass (prompt, parse, validate).
  MeetingCoachReport.swift        # Post-meeting: finaliseMetrics(transcript:) (code) and
                                  #   generateReport(...) (LLM). Mirrors MeetingSummaryService's shape
                                  #   (enum + static funcs, chunking via the same segment renderer).
  UI/
    CoachIslandContent.swift      # SwiftUI chip states: ambient strip / nudge / expanded checklist.
                                  #   Hosted by the notch island (notch-island-hud.md) — its
                                  #   IslandController observes AppState.activeCoachEngine; no
                                  #   separate coach panel exists.
    CoachReportView.swift         # Post-meeting Coach tab content (metrics, scorecard, report).
    CoachPresetSheet.swift        # Pre-record picker: meeting type + editable checklist + Start.

Sources/DictatorCore/Meetings/
  (extend) MeetingMeta.swift      # + coach: MeetingCoachResult? (decodeIfPresent, like notes/rawNotes)
  MeetingCoachResult.swift        # Codable: metrics, checklist outcomes, report markdown, generatedAt.
```

`MeetingCoachSignals` and `MeetingCoachNudger` are deliberately pure (no AppKit, no observation churn beyond a low-rate published snapshot) so the replay harness (§9) can drive them headless.

## 3. Signal engine — `MeetingCoachSignals`

Inputs and where they hook:

- **Levels**: `MeetingSession.startRecording` already sets `recorder.onLevel` / `micRecorder.onLevel` closures that write the private stashes (`MeetingSession.swift:254-258, 278-282`). Each closure additionally calls `coachEngine?.signals.ingest(mic:)/ingest(sys:)`. Writes go to non-observed storage (the `lastSystemLevel` comment explains why: per-buffer observation churn compounds over a long call — same rule here).
- **Transcript**: a `consumedLineCount`-style cursor over `MeetingLiveTranscriber.transcriptLines` (`MeetingLiveTranscriber.swift:61`), read on the engine's 1 Hz tick. Lines are `LiveLine{speaker: "Me"|"Them", text}`.

Derived signals (all windowed where relevant; published as one `Snapshot` struct at 1 Hz so the chip re-renders at most once a second):

| Signal | Source | Notes |
|---|---|---|
| VAD per side | levels | threshold + hangover smoothing (~300 ms) so word gaps don't flicker |
| Talk ratio | VAD | rolling window (default 10 min) + whole-meeting |
| Monologue timer | VAD | continuous my-side speech with <2 s gaps |
| Interruptions | VAD overlap | my VAD starting ≥1 s into their active speech; see bleed caveat below |
| Dead air | VAD | both sides silent > N s (armed per preset; useful in interviews) |
| Pace (wpm) | transcript | word count / VAD-active duration on my recent lines |
| Filler rate | transcript | per-minute, my lines only; relative signal (see header note) |
| Question drought | transcript | minutes since my last `?`-terminated line |

**Bleed (decided: in scope for phase 1 — the user usually records on open speakers):** without headphones the mic hears the remote side, so mic VAD can fire on *their* speech. Two defences, both reusing existing machinery: (a) level dominance — only count mic-side VAD when mic level isn't tracking system level; (b) the live transcriber's coupling-model gate already classifies mic windows as bleed — its utterance-granularity verdicts retroactively cancel pending interruption counts. Nudges that depend on overlap require the stricter confirmation; nudges that only need "am I talking" don't. Thresholds live in one place for the replay harness to sweep.

To be explicit: the coach adds **no new audio capture or analysis**. It consumes the level callbacks the session already receives for its meters and the bleed verdicts the live transcriber already computes — the engine is arithmetic over streams that exist today.

## 4. Nudge engine — `MeetingCoachNudger`

A static rule table evaluated on each 1 Hz snapshot. Each rule: trigger predicate, minimum sustain, cooldown, expiry, severity. **At most one nudge visible**; higher severity preempts; everything else queues behind the cooldown.

| id | Default trigger | Sustain | Cooldown |
|---|---|---|---|
| `monologue` | my monologue > 90 s | 5 s | 4 min |
| `interrupting` | ≥2 confirmed interruptions in 5 min | — | 5 min |
| `dominating` | my talk share > 70% over window | 30 s | 8 min |
| `pace` | wpm > threshold | 60 s | 8 min |
| `ask-question` | question drought > 7 min (preset-armed) | — | 7 min |
| `checklist-pending` | unticked items + elapsed > 75% of scheduled length | — | once |
| `reminder-pending` | an **ad-hoc** item (§6a) unticked 5 min after it was added | — | 5 min per item |

(`checklist-pending` needs the meeting's scheduled end — available once `meeting-context.md`'s calendar matching lands; the rule self-disarms when no end time is known. `reminder-pending` is deliberately stronger than the passive checklist count: an ad-hoc item is an explicit "don't let me forget this", so it resurfaces until addressed or dismissed.)

Presets arm a subset and override thresholds. Copy is terse and factual ("90s monologue", "Budget not discussed yet") — never chatty, never a sound. All copy lives in one table for review.

## 5. Presets are meeting types (decision)

Coach presets are **not** a new entity. `MeetingTypeDefinition` (`Meetings/MeetingTypeDefinition.swift`) already models built-in + user-defined meeting types, persisted via `settings.customMeetingTypes` (`DictatorSettings.swift:254`), resolved by `MeetingTypeRegistry`, edited in `MeetingTypeEditor`, and already drives the notes template per type. A coach preset is a meeting type that carries coach config:

```swift
struct MeetingTypeDefinition {
    // existing: id, displayName, detail, template, detectionKeyword, isBuiltIn
    var coach: CoachConfig?          // nil = this type carries no coaching

    struct CoachConfig: Codable, Equatable, Sendable {
        var checklist: [String]      // key points to hit; edited per-meeting at start
        var rubric: String           // what "good" looks like — prose fed to the report pass
        var armedNudges: [String]    // nudge ids from §4's table
        var thresholds: [String: Double]  // sparse overrides, e.g. ["talkShareMax": 0.5]
    }
}
```

Codable: `coach` joins the persisted CodingKeys with `decodeIfPresent` (the file already drops `isBuiltIn`/`detectionKeyword` from persistence; same care here — built-ins' coach configs ship in code, only custom types persist theirs).

New built-in types with coach configs: **Initial client meeting**, **Interview (interviewer)**, **Demo / pitch**. Existing built-ins (1-on-1, stand-up, retro) gain conservative configs (no checklist, behavioural nudges only). `MeetingTypeEditor` grows a coach section (checklist editor, nudge toggles).

### Client profiles — the second checklist dimension

Meeting type alone isn't enough: the same "initial client meeting" shape needs different key points for client type B than client type A. So checklists are **composable**, not monolithic:

```swift
// settings, same persistence pattern as customMeetingTypes / vocabulary
struct CoachChecklistProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String              // slug, MeetingTypeDefinition.makeID-style
    var name: String            // "Client type B", "Acme account"
    var items: [String]
    var personIDs: [String]?    // future: links into meeting-context.md's people store,
                                // so the profile auto-suggests when those attendees match
}
var coachChecklistProfiles: [CoachChecklistProfile] = []
```

A meeting's effective checklist is the merge of three sources, each item tagged with where it came from:

```swift
struct ChecklistItem { var text: String; var source: Source; var addedAt: TimeInterval?  // seconds into meeting; nil = pre-meeting
                       enum Source: String { case preset, profile, adhoc } }
```

**Pre-record flow**: `MeetingsWindow.startRecording()` (`UI/MeetingsWindow.swift:459`) currently goes straight from the Record button (⌘R) to `session.startRecording`. Insert `CoachPresetSheet` between the readiness gates and session construction: type picker (defaulting to last used, persisted as `settings.meetingLastPresetTypeID`), a **multi-select of client profiles** (last-used remembered per profile), the merged checklist shown and editable for this meeting, and Start / Start-without-coach. The chosen type is written to `meta.meetingType` **explicitly** (today it stays `.auto` until the notes pass detects it) — so the notes template and the coach both follow from one choice. Per-meeting checklist edits are stored on the session, not back onto the type or profile.

Auto-suggestion from `meeting-context.md`: type from the calendar event title (its v1), profiles from matched attendees/company (once the people store links land). The sheet gets "suggested" badges when those arrive.

## 6. Checklist watcher (live LLM pass)

Lives inside `MeetingNotesAccumulator`'s existing loop rather than running its own — one live LLM consumer, strictly serialised. After the additive notes pass (and ahead of the slower correction pass) in `tick()` (`MeetingNotesAccumulator.swift:232`), if a coach checklist exists and has unticked items:

- **Cadence/cursor**: own `lastChecklistLineCount` cursor; adaptive cadence (decided) — for the first 5 minutes it may fire on consecutive ticks (~10–20 s; intros and agenda-setting tick most items early), then settles to every 3 ticks (~30 s). Only when new lines exist; skipped entirely when the additive pass overran the tick (notes win contention by construction).
- **Prompt contract** (mirrors the correction pass's tight-output discipline, `MeetingNotesAccumulator.swift:515`): numbered unticked items + recent transcript lines; output is `DONE n` lines or nothing; anything else is ignored by the parser. Items only tick monotonically; a tick records the triggering transcript position so the post-meeting scorecard can cite it.
- **Prefilter**: skip the LLM call when no recent line shares a content word (≥4 chars) with any unticked item — the same cheap-anchor idea as `Pipeline.passOnePreservesContent`. Saves most calls in the long stretches between checklist moments.
- Engine access via `settings.activeLLMEngine()?.assist(selection:instruction:systemPrompt:priorTurns:summary:cancellation:)` exactly as the notes passes do.

When live notes are disabled but coaching is on, the accumulator still runs in a checklist-only mode (its notes passes gated off) — the loop machinery is the shared asset.

### 6a. Ad-hoc items mid-meeting ("oh — I need to remember to say X")

Mid-meeting, ideas arrive that must not be forgotten. This is *not* the pad's job: the pad is passive notes you write; a checklist item is a **tracked promise** — the watcher monitors for it, the chip shows it pending, and `reminder-pending` (§4) resurfaces it until addressed. The engine exposes:

```swift
func addChecklistItem(_ text: String)   // source: .adhoc, addedAt: now
func dismissChecklistItem(id:)          // "never mind" — leaves the scorecard as dismissed, not missed
```

Rules specific to ad-hoc items:

- **Matching is scoped to transcript after `addedAt`** — the watcher only offers an ad-hoc item against lines newer than its creation, so speech from minute 5 can't falsely tick a reminder created at minute 30. (The watcher's numbered-items prompt simply omits an item until its first eligible lines exist.)
- They arm `reminder-pending` automatically; preset/profile items never do.
- The post-meeting scorecard (§8) reports them as their own group — "you flagged this mid-meeting and didn't get to it" is the single most valuable line the coach can print.

**Capture paths** (decided — voice capture was considered and dropped: typed paths cover it, and speaking reminders aloud mid-call is awkward in practice):
1. Quick-add field in the chip's expanded state and in the live pane's checklist panel.
2. Pad lift: a line typed in the meeting pad starting with `!` is lifted into the checklist. The pad autosave path (`MeetingSession.updatePad`) already sees every edit; the pad text itself stays untouched, and a lifted line is hashed per session so later pad edits don't re-lift it. One keystroke ahead of the thought, zero new UI.

## 7. The coach chip

**Host (revised 2026-06-12)**: the chip is not its own panel — it's the meeting-time content of the **notch island** (`notch-island-hud.md`), the Dynamic-Island-style successor to the dictation HUD. The island's panel/controller provide the window mechanics (non-activating, `.statusBar` level, cross-Space, top-of-screen anchor emerging from the notch); the coach contributes `CoachIslandContent` and its state machine. Precedence inside the island: an active dictation pipeline temporarily takes the surface; the coach strip resumes after.

**Engine handle**: the island's `IslandController` (app-level, constructed in `DictatorApp`, same `withObservationTracking` continuation loop as today's `HUDController`, `UI/HUDController.swift:52`) additionally observes a global coach handle: `AppState` gains `var activeCoachEngine: MeetingCoachEngine?`, set/cleared by `MeetingSession` exactly where it sets `AppState.shared.meetingRecordingStartedAt` (`MeetingSession.swift:245`, and the teardown paths at `:272` and `stopRecording`). The coach surface appears for **every** recording while `meetingCoachEnabled` is on (decided: the ambient strip is the habit-former, and unplanned meetings still get behavioural nudges — a preset only changes which nudges are armed and adds the checklist); it survives the Meetings window closing — that's the point. Per-meeting hide lives in the expanded state.

**View states**:
1. **Ambient** (default): ~180×28 pt strip — talk-ratio dot (green/amber by threshold), elapsed, `3/5` checklist count. Glanceable, ignorable.
2. **Nudge**: expands to one line of nudge copy + the signal that caused it; auto-collapses after ~8 s. No sound, no focus steal.
3. **Expanded** (click): checklist with tick states grouped by source (preset / profile / ad-hoc), a quick-add field (§6a), the four live metrics, "hide for this meeting". The quick-add field is the one place the panel needs real keyboard input — `canBecomeKey` must return true *only* while the field is focused (ScratchpadPanel has the prior art), reverting to non-activating immediately after, so the meeting app keeps focus the rest of the time.

The in-window live pane (`LiveRecordingView`, `UI/MeetingDetailView.swift:287`) gets the richer fixed panel — checklist + metrics strip — in its right-hand column alongside the existing meters/status, for second-display users.

## 8. Post-meeting: metrics + private report

**Metrics finalisation** (code, free): in `MeetingSession.runProcessor` after `processor.run` succeeds (alongside `inferSpeakerNames` / `maybeAutoRename`, `MeetingSession.swift:515-528`), `MeetingCoachReport.finaliseMetrics(transcript:)` recomputes every §3 metric from `transcript.json`'s per-word timestamps and diarized, dedup'd segments — authoritative where live signals were provisional (live can't diarize Them into people; final can report per-speaker shares). Stored as `meta.coach.metrics`. Runs for every meeting, preset or not — it's cheap and powers v3 trends.

**Report pass** (LLM): runs from `MeetingSession.generateNotes` (`MeetingSession.swift:604`) after the notes succeed — one user action ("Generate") produces notes + coach report; the Coach tab gets its own re-run button (mirrors the notes re-run affordance). Not run during `runProcessor` — same reason notes aren't: the user reviews speakers first, and `reclaimAfterProcessing` (`:557`) wants models handed back promptly.

Prompt shape mirrors `MeetingSummaryService.generateNotes` (`MeetingSummary.swift:69`): same segment renderer and chunk budget for long meetings (`:233-249`), system prompt = built-in coach prompt + rubric + the computed metrics block + checklist outcomes. Tone is **blunt and direct** (decided) — terse factual sentences in the nudges' voice, no praise padding; the addendum is the lever for anyone wanting it warmer. Grounding rules in the prompt: *the metrics are given — never invent numbers; cite checklist outcomes as computed; at most two improvement points.* Rubric selection: the explicitly chosen type's rubric, or — when the meeting ran preset-less and the notes pass's auto-detect later classified it — the detected type's rubric applied **retroactively** (decided; the live config is never changed mid-meeting). Customisation via `meetingCoachPromptAddendum` / `meetingCoachPromptOverride`, the standard pattern (`DictatorSettings.swift:169-174`).

**Storage & privacy**: everything lands in `meta.coach: MeetingCoachResult?` —

```swift
struct MeetingCoachResult: Codable, Equatable, Sendable {
    var metrics: CoachMetrics              // talk shares, monologue max, interruptions, pace, fillers/min, questions
    var checklist: [ChecklistOutcome]?     // item, source (preset/profile/adhoc), done/dismissed/missed,
                                           // addedAt, evidence position (transcript offset)
    var reportMarkdown: String?            // the LLM report; nil until generated
    var presetTypeID: String?              // which type's coach config ran
    var profileIDs: [String]?              // which client profiles were layered in
    var generatedAt: Date?
    var schemaVersion: Int
}
```

The scorecard renders by source: preset/profile items as covered/missed, ad-hoc items called out separately — "flagged mid-meeting, not addressed" leads the report. (Future, with `meeting-context.md`'s people store: missed items offer to roll forward into the suggested checklist for the next meeting with the same people.)

Decodes with `decodeIfPresent` like `notes`/`rawNotes` (`MeetingMeta.swift:149-150`). Enforcement of privacy is structural: the notes/transcript writers (`MeetingStorage` markdown mirrors, copy/export in `TranscriptView`/`MarkdownNotesView`) never read `meta.coach`, and the live mirror is given no coach reference. The Coach tab in the detail view is the only renderer.

**Crash safety (decided)**: during recording, checklist state (items + tick/dismiss/addedAt) is debounce-written to a local `coach-live.json` in the meeting folder — the live mirror's crash-recovery ethos, but a separate private file, never one of the markdown mirrors. Deleted on clean stop (the state folds into `meta.coach`); the existing crash-recovery path reads it back so mid-meeting ad-hoc adds survive.

## 9. Tuning & verification — replay harness

`scratch/coach-replay/` (gitignored, per convention): a SwiftPM CLI that takes a meeting folder, decodes `mic.caf`/`system.caf` into level streams (and replays `transcript.json` words on their timestamps), drives `MeetingCoachSignals` + `MeetingCoachNudger` headless, and prints the nudge timeline + final metrics. The 26 existing recorded meetings are the tuning corpus: sweep VAD thresholds, window sizes, and nudge triggers; eyeball "would this nudge have annoyed me here?" against meetings the user actually remembers. This is the same methodology as the diarization-threshold sweep tool already in `scratch/`.

Build verification per the usual rules: CLI `xcodebuild` with `DEVELOPER_DIR` set; no relaunch (user relaunches themselves); runtime checks via the standalone app's NSLog scraping.

## 10. Settings

```swift
var meetingCoachEnabled: Bool = true            // master; gates engine construction in startRecording
var meetingCoachChipEnabled: Bool = true        // chip can be off while in-window coaching stays on
var meetingLastPresetTypeID: String?            // pre-record sheet default
var meetingCoachPromptAddendum: String = ""     // report pass
var meetingCoachPromptOverride: String?
var coachChecklistProfiles: [CoachChecklistProfile] = []   // §5 client profiles
var meetingLastProfileIDs: [String] = []        // pre-record sheet default
// customMeetingTypes gains `coach` per §5 — no new key
```

All decode with the standard `decodeIfPresent ?? default` pattern; coach keys join the synced-keys list alongside `customMeetingTypes` (`DictatorSettings.swift:1295`).

## 11. Delivery phases

1. **Signals + metrics (no UI risk)**: `MeetingCoachSignals`, level/transcript ingestion wiring in `MeetingSession`, `finaliseMetrics` in `runProcessor`, `meta.coach.metrics` persisted, replay harness + threshold sweep. Metrics strip in `LiveRecordingView`.
2. **Nudges + island coach mode**: `MeetingCoachNudger`, `CoachIslandContent`, `AppState.activeCoachEngine` lifecycle. Behavioural nudges only (no checklist yet). **Depends on `notch-island-hud.md` phase 1** (the island core + dictation restyle), which should be built between coach phases 1 and 2. — **SHIPPED 2026-06-12** along with the island. Replay-tuned: interruptions gated past 2 min elapsed + full fresh batch to refire; 150 s global gap between any two nudges; per-kind cooldowns escalate ×2 per repeat (capped ×8); pace readings need ≥45 s of my speech in-window and discard >450 wpm denominator noise. Result on the tuning corpus: 8 nudges in a 36-min meeting with 30 real interruptions, 0 in an 80-min listening-heavy one.
3. **Presets + checklist**: `CoachConfig` on `MeetingTypeDefinition`, built-in coach configs, client profiles (`CoachChecklistProfile` + editor), `CoachPresetSheet` in the record flow, checklist watcher in the accumulator loop, checklist in chip + live pane, ad-hoc quick-add + pad lift + `reminder-pending`.
4. **Report**: `MeetingCoachReport.generateReport`, Coach tab (`CoachReportView`), prompt addendum/override settings.
5. **Later**: trends across meetings, calendar-driven `checklist-pending` + preset auto-suggestion (lands with `meeting-context.md`).

Each phase is independently shippable; CHANGELOG entries start at phase 1 (the metrics strip is user-visible).

## 12. Decisions log & remaining questions

All eight open questions were put to the user 2026-06-12 and resolved; decisions are folded into the sections above:

| Question | Decision | Where |
|---|---|---|
| Chip gating | Show for every recording while `meetingCoachEnabled` | §7 |
| `.auto` + rubric | Detected type's rubric applies retroactively to the report | §8 |
| Voice capture of ad-hoc items | Dropped — typed paths suffice | §6a |
| Pad-lift trigger | `!` line prefix only; pad text untouched | §6a |
| Crash persistence | Debounced local `coach-live.json` | §8 |
| Report tone | Blunt and direct; addendum is the warmth lever | §8 |
| Checklist watcher cadence | Adaptive — fast first 5 min, then ~30 s | §6 |
| Bleed handling | In scope phase 1 (user usually on open speakers); reuse coupling-gate verdicts + level dominance | §3 |

Still open (implementation-time, none user-blocking):

- [ ] Exact bleed/VAD thresholds and nudge trigger values — the §9 replay harness sweeps these against the 26 recorded meetings.
- [ ] **Adaptive per-side VAD floor (phase 2, found in phase 1 replay):** a fixed `vadLevel` can't serve both quiet mics (0.02 misses them) and open-speaker bleed (0.01 lets it under the bar — interruptions 13→97 on one real meeting). Track a rolling noise floor per side and threshold relative to it. Also: interruptions need the sustain gate (shipped — edge-only counting measured ~10× truth), and on system-track-less recordings (mic-only imports) everything reads as "me" — acceptable, flagged here.
- [ ] Report quality check: validate the first real blunt-tone outputs against the one-screen cap before calling phase 4 done.
- [ ] Pad-lift edit semantics: an already-lifted `!` line that gets edited — new item or ignore? Default: hash-once, never re-lift.
