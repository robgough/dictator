# Meetings Feature — Implementation Plan

A new menu-bar entry "Meetings…" opens a window for recording (mic + system audio via ScreenCaptureKit) or importing audio files, then transcribes + diarizes the result. This plan builds on the already-decided architecture and grounds every step in existing files.

## 1. Module structure

New module rooted at `Sources/Dictator/Meetings/`. Pure-Foundation pieces that don't depend on AppKit/SwiftUI live in `Sources/DictatorCore/Meetings/` so the iOS target stays clean (but won't link them — see project.yml below).

```
Sources/Dictator/Meetings/
  MeetingSession.swift                  # @Observable state machine for ONE meeting (live record or post-process)
  MeetingsStore.swift                   # @Observable enumeration of saved meetings on disk (mirrors DictationHistory.swift)
  MeetingAudioRecorder.swift            # SCStream lifecycle + writes mic.caf / system.caf (sibling to Audio/AudioRecorder.swift)
  MeetingProcessor.swift                # Post-record / post-import pipeline: ASR + diarize + align + merge
  MeetingSummary.swift                  # Optional MLX summary pass (decisions / action items / narrative)
  ScreenRecordingPermission.swift       # SCShareableContent.current probe + Settings deep-link helper
  UI/
    MeetingsWindow.swift                # NavigationSplitView root, owns the window controller
    MeetingsWindowController.swift      # NSWindowController + WindowGroup glue (modelled on AssistantResultWindow.swift)
    MeetingSidebarList.swift            # Sidebar rows (title, date, duration)
    MeetingDetailView.swift             # Live or completed transcript pane
    LiveRecordingView.swift             # Timer, dual level meters, stop button
    TranscriptView.swift                # Speaker-coloured turns, rename, copy, export
    ImportPickerView.swift              # NSOpenPanel wrapper for file import
    SummaryPanel.swift                  # Decisions / action items / summary section, with re-run button

Sources/DictatorCore/Meetings/
  MeetingTranscript.swift               # Codable transcript.json schema
  MeetingMeta.swift                     # Codable meta.json schema
  MeetingStorage.swift                  # Path helpers: storageRoot(), session(uuid:), files

Sources/Dictator/Services/
  (extend) ServiceHolders.swift         # Add DiarizerServiceHolder

Sources/DictatorCore/Models/
  (extend) ModelStorage.swift           # Add diarizationRoot()

Sources/DictatorCore/Audio/
  AudioResampler.swift                  # Lift the static resampleToTarget helper out of AudioRecorder so MeetingProcessor can reuse it
```

Each `.swift` mirrors a known sibling:
- `MeetingsStore.swift` mirrors `History/DictationHistory.swift` — `@MainActor @Observable`, JSON-backed enumeration, append/remove/clear, pruning.
- `MeetingSession.swift` mirrors `Pipeline.swift` in shape (state enum + `@Observable` owner), but lives separately and does not share the HUD.
- `MeetingAudioRecorder.swift` mirrors `Audio/AudioRecorder.swift` — generation counter, async start, observers — but using `SCStream` instead of `AVCaptureSession`.
- `MeetingProcessor.swift` mirrors `Pipeline.runPostCapture(...)` (it's the "after-the-capture" pipeline).
- `MeetingSummary.swift` mirrors `LLM/MLXLLMService.swift`'s `summariseConversation` shape — system prompt + structured output.

## 2. State machine — `MeetingSession`

`MeetingSession.swift` defines an `@MainActor @Observable final class MeetingSession` keyed by `id: UUID`. There is one instance per meeting; the window holds a strong ref to either the currently-recording session OR the currently-selected past session.

```
enum MeetingState: Equatable {
    case idle                                                       // freshly created, nothing happening
    case requestingPermissions                                      // probing TCC for Screen Recording + Mic
    case warmingUp                                                  // SCShareableContent.current + SCStream.start in flight
    case recording(elapsed: TimeInterval, micLevel: Float, sysLevel: Float)
    case stopping                                                   // SCStream.stop in flight, files flushing
    case captured(folder: URL)                                      // audio written; awaiting processing
    case loadingASR(progress: Double)                               // ensureLoaded on Parakeet
    case transcribingMic(progress: Double)
    case transcribingSystem(progress: Double)
    case loadingDiarizer(progress: Double)
    case diarizing(progress: Double)
    case merging                                                    // align + chronological merge
    case ready                                                      // transcript.json on disk and loaded
    case summarising(progress: Double)                              // optional MLX pass
    case failed(String)
}
```

Transition triggers:
- `start()` → permission probe → `.warmingUp` → recorder's onReady fires → `.recording`
- A `Timer.publish` on a 0.25s cadence advances `elapsed` and pulls fresh levels from the recorder (matching `AudioRecorder.onLevel` shape).
- `stop()` → `.stopping` → recorder flushes both `AVAudioFile`s → `.captured`
- `MeetingProcessor.run(session:)` walks through the loading/transcribing/diarizing/merging states.
- Optional `runSummary()` → `.summarising` → flips back to `.ready` when done.

What's persisted: meta.json + transcript.json (see below), per-session folder of audio files. The state enum itself is in-memory only — on app relaunch a session loaded from disk starts in `.ready` (or `.captured` if processing didn't finish before quit).

## 3. Data model — on-disk shape

Per-session folder: `~/Library/Application Support/Dictator/Meetings/<uuid>/`

`meta.json`:
```
{
  "id": "<uuid>",
  "title": "Meeting on 2026-05-26 14:32",      // user-editable, defaults to date
  "createdAt": "2026-05-26T14:32:00Z",
  "durationSeconds": 1842.5,
  "source": "live" | "import",
  "sourceFilename": "voicemail.m4a",           // only for source=="import"
  "audioFiles": {
    "mic": "mic.caf",                           // nil for imports
    "system": "system.caf"                      // nil for imports; single-channel import goes under "system" purely as a naming convention so the rest of the pipeline doesn't branch
  },
  "speakers": [
    { "id": "me",        "displayName": "Me",        "color": "#5B9BD5", "isMe": true },
    { "id": "speaker_1", "displayName": "Speaker 1", "color": "#ED7D31" },
    { "id": "speaker_2", "displayName": "Speaker 2", "color": "#A5A5A5" }
  ],
  "summary": {                                   // optional; absent until user runs the pass
    "generatedAt": "...",
    "modelID": "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "decisions": ["..."],
    "actionItems": [{ "owner": "Alice", "text": "..." }],
    "narrative": "..."
  },
  "schemaVersion": 1
}
```

`transcript.json`:
```
{
  "segments": [
    {
      "start": 0.84,
      "end": 4.21,
      "speakerId": "me",
      "text": "Right, can we kick off?",
      "words": [                                  // optional, kept for diarizer alignment & future search; can be stripped if file gets large
        { "start": 0.84, "end": 0.95, "text": "Right" },
        { "start": 1.04, "end": 1.12, "text": "can" }, …
      ]
    }, …
  ],
  "schemaVersion": 1
}
```

`MeetingTranscript.swift` / `MeetingMeta.swift` are pure-Foundation Codable types in `DictatorCore`. `MeetingsStore` keeps an array of the lightweight `MeetingMeta` (no transcript) for the sidebar; transcripts are lazy-loaded when a meeting is selected.

Speaker labelling: diarizer outputs anonymous `speaker_0`, `speaker_1`, … which we rewrite to `speaker_1`, `speaker_2` to leave `me` free. User-editable `displayName` is the only thing the transcript view shows; `id` is stable. Colors pulled from a fixed palette in `MeetingDetailView` keyed off `id` hash for determinism.

## 4. Capture flow

`MeetingAudioRecorder.swift` owns the SCStream:

1. **Permission probe**: `SCShareableContent.current` succeeds → grant present. Failure → `ScreenRecordingPermission` returns the appropriate error and the session flips to `.failed` with a banner that deep-links to System Settings via `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
2. **Filter build**: `SCShareableContent.current` returns the on-screen content. We pick `displays.first` (we still need a video display reference for the filter, even though we discard video), and build `SCContentFilter(display:excludingApplications:exceptingWindows:)` excluding our own bundle id (`Bundle.main.bundleIdentifier ?? "net.robgough.Dictator"`). Justified: prevents the system from echoing Dictator's own start-chime back into `system.caf`.
3. **Stream config**: `SCStreamConfiguration()` with:
   - `capturesAudio = true`
   - `captureMicrophone = true`
   - `microphoneCaptureDeviceID = AudioDeviceManager.shared.preferredConnectedDevice()?.uid` when set (otherwise default)
   - `excludesCurrentProcessAudio = true` (belt + braces over the content filter)
   - `sampleRate = 48000`, `channelCount = 2` for stable downstream resampling
   - `width = 2`, `height = 2` (minimal) — video discarded but the API requires non-zero dimensions
   - `minimumFrameInterval = CMTime(value: 1, timescale: 1)` — 1 fps, cheapest
   - `queueDepth = 5`
4. **Stream start**: instantiate `SCStream(filter:, configuration:, delegate: self)`, then `addStreamOutput(self, type: .audio, ...)` for system audio, `addStreamOutput(self, type: .microphone, ...)` for mic, and `addStreamOutput(self, type: .screen, ...)` whose handler discards. `startCapture()` on a background queue.
5. **Sample handling**: `SCStreamOutput.stream(_:didOutputSampleBuffer:of:)` receives `CMSampleBuffer`s. For each type:
   - extract PCM via the same `CMSampleBufferGetDataBuffer` path as `AudioRecorder.processSampleBuffer` (mirrors lines 552–613 of `AudioRecorder.swift`)
   - write to the right `AVAudioFile` (one per type, opened on first sample so we know the format)
   - update a running RMS for the level meter; surface via `onLevel(mic:Float, system:Float)` callback consumed by `MeetingSession`
6. **VAD on mic** runs inline on each mic buffer — simple energy gate above a noise floor for ~200 ms — and segments are emitted as `(start, end)` ranges into a side array used by `MeetingProcessor` to label mic timeline regions as "me speaking" vs silence. Cheap, no model dependency.
7. **Stop**: `SCStream.stopCapture` → close both `AVAudioFile`s → MeetingSession transitions to `.captured(folder:)`.

Level meter sampling is done in the buffer handler, hopped to main via the same `Task { @MainActor }` pattern `AudioRecorder.SampleBufferForwarder` uses.

CAF format is chosen because `AVAudioFile` opens it without compression, samples land verbatim, and the file can be reopened for streaming reads by FluidAudio without any decode dependency. See risks for the disk-growth caveat — current recommendation is to use AAC `.m4a` instead.

## 5. Transcription + diarization flow

`MeetingProcessor.swift` exposes:

```
@MainActor
final class MeetingProcessor {
    func run(session: MeetingSession) async      // post-capture
    func cancel(session: MeetingSession)
}
```

Per session:

1. **ASR load**: `session.state = .loadingASR(0)`; `await ParakeetServiceHolder.shared.ensureLoaded(modelID: settings.parakeetModelID)` (reuse the existing engine; no special-cased meeting model). The current `ASREngine.transcribe(samples:modelID:)` returns a String only — for meetings we need word-level timestamps. **Concrete change required**: extend `ParakeetService` (concrete, not the protocol — keeping the protocol minimal per `ASREngine.swift` comment) with `transcribeWithTimestamps(samples:modelID:) async throws -> [TimedWord]`. FluidAudio's `AsrManager.transcribe(...)` returns a result with word timings; we wrap that into `[TimedWord(text, start, end)]`.
2. **Mic ASR**: open `mic.caf` via `AVAudioFile`, stream chunks (60-second windows) → resample to 16 kHz mono via the new shared `AudioResampler` helper → call `transcribeWithTimestamps`. Progress fraction = chunks-done / chunks-total. Mic words are tagged speakerId `"me"` whole-sale, EXCEPT where the inline VAD said the mic was silent (those word ranges get dropped — they're typically diarization noise from bleed).
3. **System ASR**: same chunked path on `system.caf`. Words tagged with a temporary placeholder speakerId.
4. **Diarizer load**: `session.state = .loadingDiarizer(0)`; `await DiarizerServiceHolder.shared.ensureLoaded()`. The holder wraps FluidAudio's `OfflineDiarizerManager` (no existing references in the codebase per grep — this is a new integration). Models live under `ModelStorage.diarizationRoot()`.
5. **Diarize system track only**: `await diarizer.diarize(audioFileAt: systemURL) -> [(start, end, speakerLabel)]`. The shortcut described in the brief — mic track is "me" wholesale — is what saves us from running diarization on the mic at all.
6. **Speaker alignment**: walk system ASR words; for each word use binary search to find which diarizer segment covers `(word.start + word.end) / 2`. Words in unassigned gaps inherit the previous word's speaker. Speakers get IDs `speaker_1, speaker_2, …` (no `_0` to keep "me" prominent).
7. **Merge**: produce a single chronological `[TranscriptSegment]` by interleaving mic + system word streams by start time, splitting whenever the speakerId changes OR a >700 ms gap appears. Each segment gets its `start`/`end`/`speakerId`/`text` and keeps the contributing `words[]`.
8. **Persist**: write `transcript.json` via `MeetingStorage.writeTranscript(_:for:)`; update `meta.json` with `durationSeconds`, `speakers[]`. `MeetingsStore.refresh()` picks up the new state.

Where it happens: `MeetingProcessor` runs on the `@MainActor` but every long-running call is `await`-ed off, so it doesn't block the UI. Each session can have one in-flight processing task; `cancel(session:)` calls `Task.cancel()` and the loops check `Task.isCancelled` between chunks (same pattern as `Pipeline.runPostCapture`).

Cancellation behaviour: cancelling mid-process keeps the audio files on disk. The session lands in `.captured(folder:)` so the user can hit "Process now" again. Cancelling mid-record discards the SCStream + closes the partial files; if the recording was >5 seconds we still write the meta and keep the partial audio so it can be processed later.

## 6. File import path

`ImportPickerView.swift` triggers `NSOpenPanel` filtered to `UTType.audio` plus `.wav`, `.mp3`, `.m4a`, `.aac`, `.flac`, `.caf`. On select:

1. `MeetingsStore.createSession(from: URL)` allocates `<uuid>/` and copies (not moves) the source file into `<uuid>/source.<ext>`. Original stays untouched.
2. Decode via `AVAudioFile` (handles every format the underlying CoreAudio decoders support), downmix to mono and resample to 48 kHz via the lifted `AudioResampler`. Write as `<uuid>/system.caf`. No mic file; meta records `audioFiles.mic = null`.
3. Route through the same `MeetingProcessor.run(session:)` path. The mic-vs-system shortcut just becomes "no mic" — diarization runs on the single track, all speakers get `speaker_N` IDs, no `me` shortcut.

Reuse: the `resampleToTarget` static at `AudioRecorder.swift:638-678` is the obvious resampler. Promotion path: lift it verbatim into `Sources/DictatorCore/Audio/AudioResampler.swift` as `enum AudioResampler { static func mono(samples:from:to:) -> [Float]? }`, then have `AudioRecorder.stop()` call into the new home. The lift is mechanical — the function is already nonisolated and Sendable-safe.

## 7. UI

`MeetingsWindow.swift` registers a `WindowGroup(id: "meetings")` in `DictatorApp.swift`'s scene body, with `.handlesExternalEvents(matching: ["meetings"])` so the URL handler can open it via `dictator://meetings`.

```
WindowGroup(id: "meetings") {
    MeetingsRootView()
        .environment(AppState.shared)
        .environment(MeetingsStore.shared)
}
.handlesExternalEvents(matching: ["meetings"])
.defaultSize(width: 980, height: 640)
```

`MeetingsRootView`:
```
NavigationSplitView {
    MeetingSidebarList(selection: $selectedID)
} detail: {
    if let id = selectedID, let meeting = store.meeting(id: id) {
        MeetingDetailView(meeting: meeting)
    } else {
        MeetingsEmptyState(onRecord: …, onImport: …)
    }
}
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        Button { startRecording() } label: { Label("Record", systemImage: "record.circle") }
    }
    ToolbarItem {
        Button { importFile() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
    }
}
```

`MeetingSidebarList` rows: speaker bubble icon, title, "2 hours · 3 speakers · 14:32".

`MeetingDetailView` has three modes driven by `session.state`:
- Live `.recording`: `LiveRecordingView` with elapsed timer, two stacked `Waveform`s (reuse `UI/Waveform.swift`), Stop button.
- Processing: progress bar + current stage label ("Transcribing mic… 42%").
- Ready: `TranscriptView` with header (title editable on focus, date, duration, speaker chips with color dots → click to rename), `ScrollView` of speaker turns rendered as colored-bar-left + speaker name + utterance text with `textSelection(.enabled)`. Toolbar adds Copy All / Export… / Summarise / Delete buttons. Summary section below the transcript when present.

Search across meetings → punted to v2 per the brief.

## 8. Menu bar wiring

Edit `Sources/Dictator/UI/MenuBarContent.swift` to insert a new `Button` in the bottom row between "Settings…" and "Setup…" (around line 47):

```
Button {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "meetings")
} label: {
    Label("Meetings…", systemImage: "person.2.wave.2")
}
```

`@Environment(\.openWindow) private var openWindow` joins the existing `openSettings` environment binding at line 12.

In `DictatorApp.swift` `handleURL`, add a case `"meetings"` that calls `NSApp.sendAction` against a stored `openWindow` closure (captured the same way `openSettingsAction` is in `AppState.swift:20`). No keyboard shortcut in v1; the brief leaves it open.

## 9. Service holders

Extend `Sources/Dictator/Services/ServiceHolders.swift` with:

```
@MainActor
enum DiarizerServiceHolder {
    static let shared = DiarizerService()
}
```

`DiarizerService` (new, `Sources/Dictator/Transcription/DiarizerService.swift`):
- Mirrors `ParakeetService.swift` shape exactly: `currentModelID`, `isLoading`, `@ObservationIgnored private var manager: OfflineDiarizerManager?`, `ensureLoaded()`, `unload()`, `diarize(audioFileAt:) async throws -> [DiarizationSegment]`.
- `DiarizationSegment` is `struct DiarizationSegment: Sendable { let start: TimeInterval; let end: TimeInterval; let speakerLabel: String }`.
- One catalog entry only at first (`pyannote-3.1` or whatever FluidAudio expects); models live under `ModelStorage.diarizationRoot()`.

Add to `Sources/DictatorCore/Models/ModelStorage.swift`:
```
static func diarizationRoot() -> URL {
    let dir = root().appendingPathComponent("diarization", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
```

## 10. Model download UX

Diarization weights: pyannote 3.1 segmentation + WeSpeaker embedding via FluidAudio. Combined size order-of-magnitude: ~80–150 MB on disk, modest enough that we can offer a one-click download on first meeting attempt rather than building a full Models pane row.

Path: on first `Meetings → Record`, if `DiarizerService.modelsExist == false`, the detail view shows a "Download diarization model (~120 MB)" card with progress bar — same shape as the existing onboarding download cells. Once on disk, never asked again. Settings → Models gains a fourth subsection "Diarization" mirroring the Parakeet section (`ModelManager` extended with `diarizationStates: [String: ModelDownloadState]`, `downloadDiarizer / cancelDiarizerDownload / removeDiarizer / verifyDiarizer`) so power users can manage manually.

Size + RAM numbers go in a new `ModelCatalog.diarizationModels` array following the `ParakeetModel` shape verbatim.

## 11. Permissions

Two `Info.plist` keys to add in `project.yml` under `targets.Dictator.info.properties`:

```yaml
NSScreenCaptureUsageDescription: "Dictator only uses screen recording to capture the audio of a meeting — both your microphone and the audio coming out of your speakers — so it can transcribe a call into a single timeline with multiple speakers. Nothing on your screen is captured or stored."
NSMicrophoneUsageDescription: "Dictator needs microphone access to listen and transcribe your speech."
```

The first key is the critical new grant. Copy is deliberately specific about "audio, not pixels" because users absolutely balk at "screen recording".

Permission flow: `ScreenRecordingPermission.probe()` calls `SCShareableContent.current` once. Success → granted. Failure with `SCStreamErrorCode.userDeclined` → not yet granted. On not-granted, the Meetings detail view shows a banner with the explanation copy plus a "Open System Settings" button that fires `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)`. No retry loop — TCC requires app restart anyway, which we surface in the banner.

Mic permission reuses the existing `Audio/MicPermission.swift` flow; no change needed.

## 12. `project.yml` changes

Under `targets.Dictator`:
- `sources` already covers `Sources/Dictator` and `Sources/DictatorCore`, so the new files land automatically — no edits needed there.
- `info.properties`: add `NSScreenCaptureUsageDescription` (see above).
- `dependencies`: ScreenCaptureKit is a system framework included by default on macOS 26 — `@import ScreenCaptureKit` is enough. No explicit linker entry needed (it's a public framework). Same for AVFoundation. Confirm by linking once.
- No new SPM dependencies — diarization rides on the existing `FluidAudio` package entry (lines 55–57).

Under `targets.Dictator.info.properties.CFBundleURLTypes`, the existing `dictator` URL scheme already handles the routing — just teach the `AppDelegate.application(_:open:)` switch about a `"meetings"` host.

## 13. Settings additions

Add to `Sources/Dictator/Settings/DictatorSettings.swift`:

```
// Meeting-related
var meetingAutoDeleteAfterDays: Int          // 0 = never delete, default 0
var meetingSummaryEnabled: Bool              // default false — opt-in
var meetingSummaryPromptAddendum: String     // "" default
var meetingSummaryPromptOverride: String?    // nil default
```

All four go in `CodingKeys`. Local-vs-synced split: `meetingSummaryEnabled` + prompt fields are synced (cross-Mac preferences); `meetingAutoDeleteAfterDays` is local (per-Mac storage policy). Defaults appended to `DictatorSettings.defaults`.

Settings UI: new tab "Meetings" between "Modes" and "Vocabulary" in `Sources/Dictator/UI/SettingsView.swift`'s `TabView`. Contains:
- Auto-delete picker (Never / 7 / 30 / 90 days)
- Summary section: toggle, prompt addendum + override fields (reuse the existing `PromptEditor` view used for assistant prompts)

## 14. Summary pass

`MeetingSummary.swift` defines:

```
struct MeetingSummaryResult: Codable, Equatable {
    let decisions: [String]
    let actionItems: [ActionItem]
    let narrative: String
    let modelID: String
    let generatedAt: Date
}
struct ActionItem: Codable, Equatable {
    let owner: String?    // null when the transcript doesn't say
    let text: String
}
```

Prompt (lives as `static let builtinMeetingSummaryPrompt` on `DictatorSettings`):
- system role: "You produce a structured summary of a recorded meeting transcript. The transcript is segmented by speaker — speakers are anonymous unless renamed by the user. Output STRICT JSON matching this shape: { decisions: [string], actionItems: [{owner: string|null, text: string}], narrative: string }. The narrative is 3–6 sentences, factual, no editorialising. Decisions are concrete agreed outcomes — not topics discussed. Action items are tasks with an owner if the transcript names one. If a category is empty, emit []. Output nothing except the JSON."
- user role: the rendered transcript, e.g. `[Speaker 1] (00:00–00:15): Let's start…`

Parser: `JSONDecoder().decode(MeetingSummaryResult.self, …)` with a `LLMTextUtilities.clean()`-style preprocess that strips any ```json fences the model adds.

Storage: written into `meta.json` under `summary` (see Section 3 schema). Re-run on demand button calls `MeetingProcessor.runSummary(session:)` which overwrites the previous summary block.

Validation logic: pass-validation as in the dictation passes does NOT apply here. The summary is intentionally lossy. The only failure modes we guard:
1. JSON parse failure → keep previous summary if any, surface "Couldn't parse summary — try again" toast.
2. Empty arrays + empty narrative → same as JSON failure.

Token budget: long meetings will easily blow past the LLM's context (typical Llama 3.2 3B context = 131k tokens but with KV cache pressure we conservatively cap at 100k). For meetings longer than ~30 minutes the processor first runs `MeetingSummary.compact(transcript:)` which chunks the transcript into 10-minute windows, summarises each, then summarises the summaries (map-reduce). Cleaner than risking truncation.

## 15. CHANGELOG.md entry

Under `## Unreleased` in `CHANGELOG.md`:

```
- New "Meetings…" item in the menu bar opens a window where you can record a live meeting (both your microphone and the other side of the call, captured together) or import an existing audio file like an m4a voice memo. Dictator transcribes everything and identifies each speaker, so a Zoom or Teams call comes out as one chronological transcript with multiple speakers. Optional one-click summary pulls out decisions and action items. Recording uses macOS screen-recording permission for the audio capture — nothing on your screen is captured.
```

## 16. Risks & open questions

- **Model license audit**: pyannote 3.1 + WeSpeaker weights ship under their own licenses. pyannote's segmentation 3.0 is MIT, WeSpeaker is Apache 2.0 in most builds, but the exact FluidAudio-redistributed checkpoint needs verifying before we ship. Action: read FluidAudio's diarization README + checkpoint metadata. If license conflicts with the app's licensing model, we may need a user-driven first-run download from a third-party URL instead of bundling the resolution.
- **Storage growth**: an hour of 48 kHz stereo CAF Float32 is ~1.4 GB. Two-hour meeting × 2 channels = ~2.8 GB. Hard to ignore. **Mitigation**: switch recorder to write AAC `.m4a` instead of CAF — `AVAudioFile` supports `AVAudioFormat` with `AVFormatIDKey: kAudioFormatMPEG4AAC` directly. AAC at 96kbps is sufficient for ASR (Parakeet doesn't see meaningful WER degradation at that bitrate based on FluidAudio's reported benchmarks). Brings the 2-hour meeting down to ~170 MB total. Open question: do we want CAF for the first 60s (so a rough crash recovery is lossless) then AAC for the bulk? Probably overengineering — go AAC, accept the small re-transcription quality risk. **Recommendation**: AAC `.m4a` for v1.
- **Screen lock mid-meeting**: SCK continues to receive audio while the screen is locked on macOS 14+ (verified by Apple's own ScreenCaptureKit samples). Display sleep is fine. System sleep is not — the stream stops. Mitigation: kick off an `NSProcessInfo.beginActivity` assertion of `.idleSystemSleepDisabled` while a meeting is recording. Surface in the UI: "Your Mac won't sleep while recording".
- **HDCP-protected audio**: SCK refuses to capture from protected sources (some Apple Music / Apple TV tracks). For meeting apps (Zoom, Teams, Meet) HDCP doesn't apply. Risk is low but worth documenting in onboarding copy.
- **Battery / thermal**: an hour of continuous CoreML inference (Parakeet TDT) running post-meeting drains noticeably. Post-process happens after the meeting ends, so the user isn't actively waiting on it for the call — we run with `.utility` QoS so the OS can throttle. Surface progress so they can quit if needed. Live recording itself is cheap (no inference in the live path — just file writes).
- **Live-transcription** is NOT in this plan, per the brief — post-process only. If we later want live, it's an additive feature: re-route SCStream buffers through Parakeet's streaming path AND fire the diarizer on a sliding window. Big lift, separate PR.
- **Concurrent meeting + dictation**: the existing Pipeline owns the mic via AVCaptureSession; if a meeting is recording when the user hits the dictation hotkey, AVCaptureSession will fail to claim the mic. v1 behaviour: Pipeline fails cleanly with "Dictator is currently recording a meeting — stop the meeting first". Add to the `.failed` message in `AudioRecorder.handleStartFailure`.
- **What about preferring stereo on the system track?** Diarization works fine on mono and FluidAudio's pipeline downmixes anyway. We capture stereo because SCK's default is stereo and the resample-to-mono happens at processor time.

## 17. Phased delivery

**v0.1 (MVP, first PR)** — capture-and-import only, no diarization, no summary:
- All files in Section 1 except `MeetingProcessor` diarization integration and `MeetingSummary.swift`
- `MeetingAudioRecorder` writing two `.m4a` files via SCStream
- Menu bar entry + Meetings window + sidebar/detail layout
- Post-record runs Parakeet on each track, labels mic as "Me" and system as "Other" (single speaker), produces transcript.json
- Import path works for `.m4a` / `.wav` / `.mp3`
- Permission flow + banner
- Settings tab placeholder ("Auto-delete after" only)
- CHANGELOG bullet trimmed: "...transcribes everything (single 'Other' speaker for the remote side — multi-speaker identification coming next release)."

This is shippable: power users get a working meeting recorder with searchable transcripts.

**v0.2** — diarization on the system track:
- `DiarizerService` + `DiarizerServiceHolder`
- `MeetingProcessor` extended with the alignment + merge logic
- Settings → Models pane gets the diarization row
- First-run download UX
- CHANGELOG bullet edited to drop the "coming next release" caveat

**v0.3** — summary pass + polish:
- `MeetingSummary.swift` + UI panel
- Settings tab: summary toggle, addendum, override
- Speaker rename + color customisation
- Export to plain text + markdown
- `MeetingSession` crash-recovery (restart-with-orphan-folder → resume at `.captured`)

**v0.4** (future) — search across transcripts, live transcription, sharing.

Scope for first PR is v0.1: roughly 12 new files, one menu bar button, one new Info.plist key, one new entitlement check, one CHANGELOG line. The plumbing for v0.2/v0.3 — service holders, state cases, on-disk schema — is designed up front in this plan so the v0.1 PR doesn't bake in shapes that need redesign.

### Critical Files for Implementation

- `Sources/Dictator/Pipeline/Pipeline.swift` (state-machine shape to mirror in `MeetingSession`)
- `Sources/Dictator/Audio/AudioRecorder.swift` (capture-recorder pattern + the resampler to lift)
- `Sources/DictatorCore/Transcription/ParakeetService.swift` (FluidAudio integration pattern, needs `transcribeWithTimestamps` extension)
- `Sources/Dictator/UI/MenuBarContent.swift` (where the "Meetings…" item is wired)
- `project.yml` (Info.plist key for screen-capture permission + sources are already globbed)
