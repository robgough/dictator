import Foundation
import Observation
import AppKit
import os

/// Which capture flow is driving the pipeline.
///
/// Replaces the `isAssistant` flag the recording states used to carry: with
/// journal dictation there are three flows, not two, and each gets its own
/// HUD tint and wording. The tint mapping lives in the UI layer
/// (`HUDPalette`) — Pipeline has no business importing SwiftUI.
enum CaptureKind: Equatable, Sendable {
    case dictation
    case assistant
    case journal
}

/// What a window-vision read is being done *for* — the only thing the HUD needs
/// to know about it.
enum ScreenReadPurpose: Equatable, Sendable {
    /// Dictation: mining proper-noun spellings out of the focused window so the
    /// formatter writes names the way the user's own screen writes them.
    case spellings
    /// Assistant Mode: reading what the window actually says, because the
    /// spoken instruction is about it.
    case content
}

enum PipelineState: Equatable {
    case idle
    case capturingSelection
    /// AVAudioEngine has been asked to start but hasn't begun producing
    /// buffers yet. On wired mics this flashes by in milliseconds; on
    /// Bluetooth (AirPods etc.) it can last 2–5 s while macOS negotiates
    /// HFP. Surfaced in the HUD so the user understands they're not yet
    /// being recorded.
    case warmingUp(kind: CaptureKind)
    case recording(level: Float, kind: CaptureKind, interim: String)
    case transcribing
    /// Waiting on the window-vision read that was kicked off at trigger time.
    /// Only entered when there is actually a vision task outstanding — normally
    /// it finished during the recording and this is skipped entirely. It earns
    /// its own case because the wait can be many seconds on an MLX vision model,
    /// and sitting in `.transcribing` for that time told the user something
    /// plainly untrue: transcription was long since finished.
    ///
    /// Carries what the read is *for* because the two flows using it mean very
    /// different things by it, and one label can't serve both honestly. On a
    /// dictation the user asked for text, not for the screen to be looked at —
    /// "Reading screen", several seconds at a time on every polished run, reads
    /// as the app watching them rather than working on their sentence. Naming
    /// the product (the spellings) matches every other stage here — Formatting,
    /// Polishing, Translating all say what comes out, not what gets touched.
    /// In Assistant Mode the instruction is *about* the window, so there the
    /// literal label is the reassuring one and it stays.
    case readingScreen(purpose: ScreenReadPurpose)
    case formatting
    case fixingGrammar
    case restructuring
    case translating
    case assisting
    case compacting
    case done(text: String, pasted: Bool, note: String?)
    case failed(String)

    var iconName: String {
        switch self {
        case .idle: "waveform"
        case .capturingSelection: "selection.pin.in.out"
        case .warmingUp: "antenna.radiowaves.left.and.right"
        case .recording: "waveform.badge.mic"
        case .transcribing: "waveform.badge.magnifyingglass"
        case .readingScreen(let purpose):
            switch purpose {
            case .spellings: "textformat.abc.dottedunderline"
            case .content: "eye"
            }
        case .formatting: "sparkles"
        case .fixingGrammar: "text.badge.checkmark"
        case .restructuring: "list.bullet.indent"
        case .translating: "globe"
        case .assisting: "wand.and.stars"
        case .compacting: "archivebox"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    var isActive: Bool {
        if case .idle = self { return false }
        if case .done = self { return false }
        if case .failed = self { return false }
        return true
    }

    /// Whether the user can usefully abort what's happening. True while the
    /// pipeline is doing something interruptible (recording or any thinking
    /// state); false in idle / done-linger / failed where there's nothing to
    /// stop. Drives both the HUD's hover-cancel button and the panel's
    /// `ignoresMouseEvents` so click-through works during done-linger.
    var canCancel: Bool {
        switch self {
        case .idle, .done, .failed: false
        default: true
        }
    }
    /// True while audio is actually being captured — warming up or recording.
    /// The Chat composer's dictate button follows this so it can't get stuck
    /// lit when a capture ends by some route other than its own button.
    var isCapturing: Bool {
        switch self {
        case .warmingUp, .recording: return true
        default: return false
        }
    }

}

@MainActor
@Observable
final class Pipeline {
    private(set) var state: PipelineState = .idle
    private(set) var lastResult: String = ""

    /// Whether the delivery the HUD is currently showing went to the journal
    /// file rather than into an app.
    ///
    /// It lives here rather than as a fourth associated value on
    /// `PipelineState.done` because every `.done` switch in the UI would have
    /// to be rewritten for a fact only the terminal frame cares about. The
    /// views read it in their `.done` branch to pick the right icon and
    /// wording — otherwise a journal entry reports itself as "Copied to
    /// clipboard", which is not what happened to it.
    private(set) var lastDeliveryWasJournal = false

    /// The file the last journal entry was appended to, while the HUD is
    /// still showing it. Clicking the HUD opens it — the moment you've just
    /// spoken a thought into a file is exactly when you might want to look at
    /// it, and hunting for the path afterwards is friction the feature can
    /// do without.
    private(set) var lastJournalURL: URL?

    /// Mode driving the in-flight dictation. Captured at `startRecording()`
    /// time from `settings.activeMode(forFrontmostBundleID:)`, then frozen
    /// for the rest of the pipeline run so mid-recording cycling (Step 2)
    /// affects only the current recording, and post-finish settings churn
    /// can't change pass behaviour underneath us.
    private(set) var currentMode: DictationMode = .clean

    /// Fired after every successful Assistant Mode turn so the host can show
    /// (or refresh) the result window. `surfaceWindow` is true when the
    /// result wasn't pasted in place — either DRAFT mode or a paste-fallback
    /// to copy — and the user therefore needs the window to actually read
    /// the output. When false, the host should only refresh the window if
    /// it's already visible (e.g. user is following along a REPLACE thread
    /// they've kept open).
    var onAssistantTurnCompleted: ((_ thread: ChatThread, _ surfaceWindow: Bool) -> Void)?

    /// Set by AppState — asks the host whether the result window is currently
    /// on-screen, and what thread it's displaying. Pipeline uses these to
    /// decide whether a new assistant invocation is a continuation of the
    /// active thread. Kept as closures so Pipeline doesn't import UI types.
    var resultWindowIsVisible: (() -> Bool)?
    var resultWindowThreadID: (() -> UUID?)?

    /// The thread that will be continued on the next assistant call, if
    /// continuation triggers fire. Set after every successful turn and cleared
    /// by the result window closing.
    ///
    /// Held by id, not by value: the same thread can be open in the chat window
    /// at the same time, and two copies of it would race. `ChatStore` is the
    /// single owner; this is a pointer into it.
    private(set) var activeThreadID: UUID?

    /// The active thread as it stands right now, or nil if it's gone.
    var activeThread: ChatThread? {
        guard let activeThreadID else { return nil }
        return ChatStore.shared.thread(id: activeThreadID)
    }

    /// Whether the *currently in-flight* assistant invocation is a follow-up
    /// to the active conversation. Set when recording starts so the HUD can
    /// show "Following up" instead of "Speak your instruction". Read by the
    /// HUD view during `.recording(kind: .assistant, …)`.
    private(set) var nextAssistantIsContinuation: Bool = false

    private var settings: DictatorSettings
    private let recorder = AudioRecorder()
    private let whisper = TranscriptionServiceHolder.shared
    private let parakeet = ParakeetServiceHolder.shared
    private let injector = TextInjector()
    private let audioInterrupter = AudioInterrupter()

    /// Periodic re-transcription of the in-flight audio buffer to drive the
    /// HUD's "preview" line. Spun up at recording start, torn down when
    /// recording ends. We re-run the same offline ASR path used for the
    /// final transcript, so quality matches and there's no streaming-config
    /// edge case to tune. Parakeet-only.
    @ObservationIgnored private var interimSnapshotTask: Task<Void, Never>?

    /// Resolves the currently-selected engine to the concrete service plus
    /// the model ID it should run with. Both call sites in the pipeline
    /// (dictation and assistant) go through here so a single switch carries
    /// the engine choice everywhere.
    private var activeASR: (engine: any ASREngine, modelID: String) {
        switch settings.transcriptionEngine {
        case .whisper:
            return (whisper, settings.whisperModelID)
        case .parakeet:
            return (parakeet, settings.parakeetModelID)
        }
    }

    /// Compute a per-recording transcribe budget: 60-second floor plus
    /// 3× the audio duration, capped at five minutes. Generous enough
    /// for slow models on long clips, short enough that a real hang
    /// doesn't keep the HUD spinner up all afternoon.
    private static func transcribeBudgetSeconds(audioSamples: Int) -> Double {
        let audioSeconds = Double(audioSamples) / 16_000
        return min(300, max(60, audioSeconds * 3))
    }

    /// Watchdog that flips the pipeline from `.transcribing` to
    /// `.failed` if the engine doesn't return within `budget` seconds.
    /// Cancellation upstream is cooperative — WhisperKit / FluidAudio
    /// may not check it — so we treat the engine call as fire-and-
    /// forget on timeout: cancel the in-flight pipeline task so its
    /// post-transcribe code bails on `Task.isCancelled`, surface a
    /// clear error to the user via the HUD, and let the orphaned
    /// transcribe drain in the background. The guard on `state` is
    /// what stops the watchdog from clobbering a subsequent dictation
    /// — if the user has already moved past the transcribing phase,
    /// the timeout is moot.
    private func startTranscribeWatchdog(budget: Double) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(budget))
            guard let self, !Task.isCancelled else { return }
            guard case .transcribing = self.state else { return }
            self.inFlightTask?.cancel()
            self.inFlightAssistant = nil
            self.nextAssistantIsContinuation = false
            self.fail("Transcription took longer than \(Int(budget))s and was aborted. Try again, and if it keeps happening switch transcription engine or model in Settings.")
        }
    }

    /// Resolves the currently-selected LLM engine. Thin wrapper around
    /// `settings.activeLLMEngine()` — kept private to Pipeline because the
    /// dispatch needs to happen on the *current* settings snapshot, not whatever
    /// AppState happens to hold right now.
    private func currentLLM() -> (any LLMEngine)? {
        settings.activeLLMEngine()
    }

    private var doneFader: Task<Void, Never>?

    /// The post-capture or assistant pipeline currently running. Stored so
    /// `cancelInFlight()` can abort it — LLM generation checks `Task.isCancelled`
    /// inside its didGenerate callback and stops at the next token, then the
    /// awaiting code bails before delivery.
    private var inFlightTask: Task<Void, Never>?

    /// Monotonic id for warmup attempts, so a watchdog armed for one press
    /// can't shoot down a later (healthy) `.warmingUp` that happens to be
    /// in flight when its timer fires.
    private var warmupAttempt = 0

    /// Highest warmup attempt whose main-actor watchdog has actually *run*
    /// (regardless of what its guards decided). Written by the watchdog
    /// task on main, read by the off-main starvation sentinel — see
    /// `armWarmupWatchdog`. Lock-protected because the sentinel reads it
    /// from a GCD utility queue.
    @ObservationIgnored private let watchdogHeartbeat = OSAllocatedUnfairLock(initialState: 0)

    /// Highest warmup attempt whose `.warmingUp → .recording` transition has
    /// actually run on the main actor (set in `handleRecorderReady`). Read
    /// off-main by the stall sampler: if the recorder reports the mic is
    /// physically live but this hasn't advanced, the main actor is wedged and
    /// it's worth sampling the real stack. Lock-protected for the off-main read.
    @ObservationIgnored private let readyConfirmedAttempt = OSAllocatedUnfairLock(initialState: 0)

    /// How long after arming to check for a wedge worth sampling. Much shorter
    /// than `warmupWatchdogSeconds` (12 s) because everyday stalls are 1–5 s and
    /// the 14 s starvation sentinel misses them entirely.
    private static let stallSampleSeconds: Double = 2

    /// Hard ceiling over the recorder's own per-phase watchdogs: their
    /// worst legitimate chain (resolution timeout → default fallback →
    /// Bluetooth warmup budget) sums to ~10 s, so anything past this means
    /// both `onReady` and `onStartFailed` were swallowed — the recorder
    /// silently no-oped, a callback was lost, or an invariant broke. The
    /// recorder-level watchdogs can't cover that class of failure; without
    /// this one the HUD shows "Connecting microphone" forever.
    private static let warmupWatchdogSeconds: Double = 12

    /// Arm after entering `.warmingUp`. Two layers:
    ///
    /// 1. A main-actor watchdog: if we're *still* in `.warmingUp` for the
    ///    same attempt when the timer fires, dump the recorder's state to
    ///    the mic diagnostics log, reset the recorder, and fail the
    ///    dictation cleanly so the user gets an actionable message instead
    ///    of a hung HUD.
    /// 2. An off-main starvation sentinel: every safety net above —
    ///    including layer 1 — is a main-actor task, so none of them can
    ///    fire when the *main thread itself* is wedged. That's a real
    ///    failure mode, not hypothetical: on 2026-06-07 a WindowServer
    ///    sensor-indicator bug blocked this app's render commits for 118 s
    ///    and froze the HUD at "Connecting microphone" while the mic
    ///    recorded fine and every watchdog sat unrun in the main queue.
    ///    The sentinel runs on a GCD queue, checks whether layer 1 managed
    ///    to run at all, and writes the verdict to the diagnostics log so
    ///    a frozen-UI stall is distinguishable from an audio failure.
    private func armWarmupWatchdog() {
        warmupAttempt &+= 1
        let attempt = warmupAttempt
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmupWatchdogSeconds))
            // Prove to the sentinel that main is alive — before any guard.
            self?.watchdogHeartbeat.withLock { $0 = max($0, attempt) }
            guard let self, attempt == self.warmupAttempt else { return }
            guard case .warmingUp = self.state else { return }
            MicLog.log("Pipeline: still .warmingUp after \(Int(Self.warmupWatchdogSeconds))s — recorder { \(self.recorder.debugState) }. Failing the attempt.")
            // stop() both orphans an in-flight start (generation bump) and
            // tears down a zombie session if one is improbably live.
            _ = self.recorder.stop()
            self.inFlightAssistant = nil
            self.fail("Mic didn't start. Try again — if it keeps happening, pick a different input in Settings.")
        }
        // Fast stall sampler: ~2 s after arming, if the recorder reports the
        // mic is physically live but the main actor never promoted us to
        // .recording for this attempt, main is wedged — dump its real stack
        // via `/usr/bin/sample` instead of guessing. Gated on the mic being up
        // so a genuinely slow device (BT warmup) doesn't trip it.
        let micLiveForSample = recorder.sessionPhysicallyLive
        let confirmed = readyConfirmedAttempt
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.stallSampleSeconds
        ) {
            guard confirmed.withLock({ $0 }) < attempt else { return }
            guard micLiveForSample.withLock({ $0 }) else { return }
            MicLog.captureStallSample(reason: "warmup attempt \(attempt): mic physically live but main actor hasn't promoted to .recording after \(Int(Self.stallSampleSeconds))s")
        }

        // Give the main-actor watchdog 2 s of grace past its deadline
        // before declaring starvation.
        let heartbeat = watchdogHeartbeat
        // Read off-main so we can report the *honest* state: if the mic is
        // physically capturing (flag set on the audio thread after
        // startRunning) while this watchdog is starved, the audio is fine and
        // only the main-actor UI update is wedged — a WindowServer stall, not
        // an audio failure. The lock is Sendable; capture it, not `self`.
        let micLive = recorder.sessionPhysicallyLive
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.warmupWatchdogSeconds + 2
        ) {
            guard heartbeat.withLock({ $0 }) < attempt else { return }
            if micLive.withLock({ $0 }) {
                MicLog.log("Main thread starved: warmup watchdog for attempt \(attempt) hasn't run \(Int(Self.warmupWatchdogSeconds) + 2)s after arming — but the mic IS physically live and capturing. Only the main-actor UI update is stuck. This is a macOS WindowServer/render-commit wedge (the sensor-indicator-layer bug), not an audio failure — it usually clears on logout/reboot.")
            } else {
                MicLog.log("Main thread starved: warmup watchdog for attempt \(attempt) hasn't run \(Int(Self.warmupWatchdogSeconds) + 2)s after arming, and the mic isn't confirmed live yet — UI is frozen (main-actor tasks can't get scheduled). Suspect render/WindowServer health, not audio.")
            }
        }
    }

    private var pendingNote: String?

    /// Stages of the current dictation, captured as each pass completes so we can
    /// snapshot the full journey into the history at the end.
    private struct InFlight {
        var raw: String = ""
        /// Every accepted transformation, in order — the LLM passes the mode's
        /// style resolved to, plus the automatic paragraph split. This is what
        /// the History pane renders; the four fields below are the legacy
        /// fixed-pass slots, still written so old History rows keep working.
        var stages: [DictationStage] = []
        var formatted: String?
        var dictionaryCorrected: String?
        var tidied: String?
        var restructured: String?
        /// Text surrounding the insertion point in the focused app, captured
        /// at hotkey press (when the mode opts in and AX can read it). Feeds
        /// the formatter pass as read-only terminology/style context. NOT
        /// written into the history record — context is ephemeral by design.
        var context: InsertionContext?
        /// In-flight window-vision capture, kicked off at hotkey press and run
        /// concurrently with recording (see `WindowVisionContext`). Resolved
        /// into `visionTerms` once transcription completes — by which point it's
        /// almost always already done, so it adds no latency to delivery.
        var visionTask: Task<[String], Never>?
        /// When the vision read was kicked off, so `resolveVisionTerms` can say
        /// how much of it the recording actually managed to hide. Diagnostics
        /// only — see the `[Vision]` NSLog lines.
        var visionStartedAt: CFAbsoluteTime = 0
        /// Distinctive terms read off the focused window by the vision model.
        /// Merged with `context.documentTerms` at the consumption sites
        /// (`combinedContext`). Empty when the mode opts out, the OS/model can't
        /// do vision, Screen Recording isn't granted, or nothing was read.
        var visionTerms: [String] = []
        /// Whether a window-vision read was started for this dictation. Kept
        /// separate from `visionTerms.count` so History can tell "vision is off
        /// for this mode" from "vision ran and found nothing useful" — they are
        /// very different answers to "is this working?", and a bare count
        /// renders both as silence.
        var visionAttempted = false
        /// Bundle ID of the app that was frontmost when the hotkey fired — the
        /// app the paste will land in. Recorded in history purely as
        /// diagnostics: join/spacing bugs are almost always app-specific, and
        /// "which app was this?" was previously unanswerable after the fact.
        var appBundleID: String?
        /// True when this capture came from the journal hotkey. Everything up
        /// to delivery is identical to a normal dictation — same transcribe,
        /// same passes, same dictionary — but `finish` appends to a file
        /// instead of pasting, and skips every insertion-point behaviour
        /// (context join, trailing space, Return) because there is no
        /// insertion point.
        var isJournal: Bool = false
        /// Seconds of audio actually transcribed, after silence trimming.
        /// Feeds the words-per-minute figure on About.
        var spokenSeconds: Double = 0
    }
    private var inFlight = InFlight()

    /// Non-nil while an Assistant Mode dictation is in progress. Used to route the
    /// release-of-hotkey event to the assistant path instead of the dictation path,
    /// and to carry the captured selection from press → release → LLM. `selection`
    /// is nil if the user had nothing selected — a valid case ("put a list here").
    /// `continuesConversation` is decided at press time (so the HUD can show
    /// "Following up") and frozen for the rest of the in-flight turn.
    private struct InFlightAssistant {
        var selection: String?
        var continuesConversation: Bool
        /// Document text surrounding the selection, captured via Accessibility
        /// at press time (always on for the assistant; nil when AX can't read
        /// the focused app). Fed to the assistant LLM as read-only reference so
        /// it can resolve "reply to this" / "make a list here" and match the
        /// document's spelling. Ephemeral — never written to history.
        var context: InsertionContext? = nil
        /// Why `context` came back without text, when it did (no focused field,
        /// focused on Dictator, field exposes no cursor…). Shown in the result
        /// window's context banner so an empty AX read is debuggable.
        var contextReason: String? = nil
        /// In-flight window-vision read-back (visible content + mined terms),
        /// kicked off at trigger time and run concurrently with the instruction
        /// recording. Resolved in `runAssistantPipeline` and merged into the
        /// context the assistant LLM sees. nil when the option is off / vision
        /// isn't supported / Screen Recording isn't granted.
        var visionTask: Task<WindowVisionContext.AssistantVision, Never>? = nil
    }
    private var inFlightAssistant: InFlightAssistant?

    /// Set by `finishAssistant` when the user releases the hotkey *before*
    /// `startAssistant`'s setup task has finished awaiting the selection
    /// grab. The setup task checks this flag after the slow await and bails
    /// cleanly to `.idle` instead of pushing the pipeline into `.recording`
    /// with no release path queued. Without this, a quick tap of the
    /// assistant hotkey leaves the engine running indefinitely.
    private var assistantReleasePending: Bool = false

    init(settings: DictatorSettings) {
        self.settings = settings
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording(_, let kind, let interim) = state {
                state = .recording(level: level, kind: kind, interim: interim)
            }
        }
        recorder.onReady = { [weak self] in
            self?.handleRecorderReady()
        }
        recorder.onStartFailed = { [weak self] error in
            self?.handleRecorderStartFailed(error: error)
        }
        recorder.onUnexpectedStop = { [weak self] message in
            self?.handleUnexpectedStop(note: message)
        }
    }

    /// Recorder finished warming up (engine running, tap installed). Promote
    /// `.warmingUp` to `.recording` so the HUD switches from "Connecting" to
    /// the live waveform. If we're not in `.warmingUp` any more (user
    /// released the hotkey while the mic was negotiating HFP) the recorder
    /// has already been told to stop; nothing to do here.
    private func handleRecorderReady() {
        guard case .warmingUp(let kind) = state else { return }
        // Mark this attempt confirmed so the off-main stall sampler knows the
        // main actor got here (and doesn't fire on a healthy start). Read into
        // a local first — the `withLock` closure is @Sendable.
        let confirmedAttempt = warmupAttempt
        readyConfirmedAttempt.withLock { $0 = max($0, confirmedAttempt) }
        state = .recording(level: 0, kind: kind, interim: "")
        if settings.playSounds { SoundEffects.shared.playStart() }
        // Engaged after the start sound so the chime itself isn't dipped
        // by the very ducking it announces. Mode is snapshotted inside
        // start(); the matching stop() restores whatever was applied.
        audioInterrupter.start(mode: settings.audioInterruption)

        // HUD preview — for dictation and the Assistant instruction alike (a
        // live draft of what you're saying; the well shows in both flows).
        // Parakeet-only (Whisper is too slow to re-transcribe a growing buffer
        // every second). When enabled we periodically snapshot the recorder's
        // buffer and run the same offline transcribe path the final result uses
        // — no streaming-config edge cases, and the preview quality matches
        // what the user will eventually see.
        if settings.realtimeInterimEnabled,
           settings.transcriptionEngine == .parakeet {
            startInterimSnapshots()
        }
    }

    /// Period between snapshot transcribes. The first snapshot fires after
    /// roughly this delay, then we wait this long *after* each transcribe
    /// completes — so longer audio paces itself naturally rather than
    /// stacking parallel inferences. A second feels responsive without
    /// melting the ANE.
    private static let interimSnapshotInterval: Duration = .milliseconds(700)

    /// Minimum audio samples (at 16 kHz) before running a snapshot. Below
    /// this AsrManager's guard rejects the input with `.invalidAudioData`.
    /// 0.4 s gives a small margin above the framework's 0.3 s floor.
    private static let interimMinSamples: Int = Int(16_000 * 0.4)

    private func startInterimSnapshots() {
        let modelID = settings.parakeetModelID
        interimSnapshotTask = Task { @MainActor [weak self] in
            // First grace period before we even try — gives the user time to
            // get a syllable or two out before we look at the buffer.
            try? await Task.sleep(for: Self.interimSnapshotInterval)
            while !Task.isCancelled, let self {
                guard case .recording = self.state else { return }
                let snapshot = self.recorder.snapshotResampled16k()
                if snapshot.count >= Self.interimMinSamples {
                    do {
                        let text = try await self.parakeet.transcribe(
                            samples: snapshot,
                            modelID: modelID
                        )
                        guard !Task.isCancelled,
                              case .recording(let level, let kind, _) = self.state else { return }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            self.state = .recording(level: level, kind: kind, interim: trimmed)
                        }
                    } catch {
                        // Interim is best-effort; a failed snapshot just
                        // means we'll try again in interval ms.
                    }
                }
                try? await Task.sleep(for: Self.interimSnapshotInterval)
            }
        }
    }

    private func tearDownInterim() {
        interimSnapshotTask?.cancel()
        interimSnapshotTask = nil
    }

    private func handleRecorderStartFailed(error: Error) {
        // Only react if we're still expecting this startup. If we've already
        // moved on (cancelled, etc.) the failure is moot.
        guard case .warmingUp = state else { return }
        inFlightAssistant = nil
        fail("Mic error: \(error.localizedDescription)")
    }

    private func handleUnexpectedStop(note: String) {
        guard case .recording = state else { return }
        let samples = recorder.stop()
        audioInterrupter.stop()
        tearDownInterim()
        guard samples.count > 8_000 else {
            fail(note)
            return
        }
        pendingNote = note
        Task { await runPostCapture(samples: samples) }
    }

    func settingsChanged(_ new: DictatorSettings) {
        settings = new
    }

    /// Rotates `currentMode` to the next entry in `settings.modes.filter(\.includeInCycle)`,
    /// wrapping at the end. No-op outside `.recording` (mid-flight passes
    /// have already snapshotted the mode; cycling after the user releases
    /// the hotkey would have no effect anyway) and when the cycle has ≤1
    /// entry. Plays a subtle click via `playArm()` so the user gets aural
    /// confirmation without staring at the HUD.
    func cycleMode() {
        guard case .recording = state else { return }
        let cycleable = settings.modes.filter { $0.includeInCycle }
        guard cycleable.count > 1 else { return }
        let currentIdx = cycleable.firstIndex(where: { $0.id == currentMode.id }) ?? -1
        let nextIdx = (currentIdx + 1) % cycleable.count
        currentMode = cycleable[nextIdx]
        if settings.playSounds { SoundEffects.shared.playArm() }
    }

    /// Next mode in the cycle order, used by the HUD to render
    /// "Tab → <next>" while recording. Returns nil when ≤1 cycleable mode.
    var nextCycleMode: DictationMode? {
        let cycleable = settings.modes.filter { $0.includeInCycle }
        guard cycleable.count > 1 else { return nil }
        let currentIdx = cycleable.firstIndex(where: { $0.id == currentMode.id }) ?? -1
        let nextIdx = (currentIdx + 1) % cycleable.count
        return cycleable[nextIdx]
    }

    /// Journal dictation. Same capture and same passes as `startRecording`;
    /// the difference is entirely at delivery, where `finish` appends to the
    /// user's journal file rather than pasting into the frontmost app.
    func startJournal() {
        startRecording(isJournal: true)
    }

    func startRecording() {
        startRecording(isJournal: false)
    }

    private func startRecording(isJournal: Bool) {
        // If we're sitting in a terminal state (.done / .failed) when the hotkey
        // fires again, snap back to .idle right now. Previously we cancelled the
        // doneFader and bailed on the guard — which permanently stranded us in
        // .done because the fader never got to flip state back.
        switch state {
        case .done, .failed:
            doneFader?.cancel()
            doneFader = nil
            state = .idle
        default:
            break
        }
        guard case .idle = state else { return }
        // A correction the user made after the *previous* dictation is most
        // likely to have happened in the seconds just before this one — they
        // fixed the name and went straight back to dictating. Report it now
        // rather than letting the watcher's timer run out.
        if settings.learnFromCorrectionsEnabled { CorrectionWatcher.shared.flush() }
        // Snapshot the mode that will drive this dictation. Resolution order:
        // (1) a mode bound to the frontmost browser's URL, (2) a mode bound to
        // the frontmost app's bundle ID, (3) the user's configured
        // defaultModeID. Frozen here so mid-pipeline settings churn or
        // app-switching can't change pass behaviour underneath us.
        //
        // A journal dictation ignores all of that: it isn't going into the app
        // in front, so that app has no business choosing how it's written.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if isJournal {
            currentMode = settings.journalMode
        } else {
            currentMode = settings.activeMode(forFrontmostBundleID: bundleID, url: frontmostBrowserURL(bundleID: bundleID))
        }
        // Start from a clean slate rather than clearing field by field. A run
        // that ended in `fail()` never reset `inFlight`, so its stages used to
        // leak into the next dictation's history record — and now that the
        // struct also carries `isJournal`, a stale flag would send a normal
        // dictation to the journal file instead of the app in front.
        inFlight.visionTask?.cancel()
        inFlight = InFlight()
        inFlight.isJournal = isJournal
        // Snapshot the text around the insertion point while focus is still
        // in the target app (the HUD is non-activating, but press time is the
        // honest reading of "where the user was when they started talking").
        // Detached because a busy app can stall AX messaging; the result
        // lands on the main actor long before Pass 1 needs it. A nil capture
        // (mode opted out, no Accessibility, focused element doesn't expose
        // ranged text) just means no context this run.
        inFlight.appBundleID = bundleID
        if currentMode.contextAwarenessEnabled {
            Task.detached(priority: .userInitiated) { [weak self] in
                let context = AXContextReader.capture(
                    maxBefore: AXContextReader.promptBeforeCap,
                    maxAfter: AXContextReader.promptAfterCap,
                    mineTerms: true
                )
                await MainActor.run { self?.inFlight.context = context }
            }
        }
        // Window-vision context: a single on-device snapshot of the focused
        // window, read for proper-noun spellings the AX text reads can't reach.
        // Kicked off here so the ~1 s capture+inference overlaps the user's
        // speech and is done before Pass 1 needs it. Detached so neither the
        // screenshot nor the model call touches the main actor; the result is
        // folded in by `resolveVisionTerms`. Gated on the per-mode opt-in, the
        // OS/model actually supporting vision, and Screen Recording being
        // granted — any of those failing just means no vision terms this run.
        // One global switch for both dictation and the assistant, on by default.
        // `isSupported` is what actually decides most of the time: it's false
        // unless a model that can read images is loaded right now.
        //
        // Skipped outright when the mode runs no LLM passes. Vision exists to
        // feed proper-noun spellings into a prompt — with no prompt there is
        // nothing to feed, so the capture and its inference are pure cost, and
        // `resolveVisionTerms` would still stop and wait for them before
        // delivering. That's the whole of the Quick mode complaint: Quick is
        // `.raw`, the fastest path in the app, and it was sitting behind a
        // screenshot read whose result it then threw away. Keyed on the passes
        // rather than on Quick's id so any `.raw` mode a user makes is just as
        // fast.
        if settings.visionContextEnabled,
           !currentMode.passes.isEmpty,
           WindowVisionContext.isSupported,
           ScreenRecordingPermission.hasAccess() {
            inFlight.visionAttempted = true
            let visionStart = CFAbsoluteTimeGetCurrent()
            inFlight.visionStartedAt = visionStart
            VisionLog.log("kick-off (mode '\(currentMode.name)')")
            inFlight.visionTask = Task.detached(priority: .userInitiated) {
                let terms = await WindowVisionContext.captureFocusedWindowTerms()
                VisionLog.log(String(format: "read DONE %.2fs after kick-off — %d term(s)",
                                     CFAbsoluteTimeGetCurrent() - visionStart, terms.count))
                return terms
            }
        }
        // Recorder start is non-blocking and asynchronous — the actual
        // engine setup runs off-main so Bluetooth HFP negotiation (2–5 s on
        // AirPods Max) doesn't beach-ball the main thread. Pipeline sits in
        // `.warmingUp` until the recorder's `onReady` fires (handled in
        // init); the HUD shows "Connecting" with the active device name for
        // the duration.
        state = .warmingUp(kind: isJournal ? .journal : .dictation)
        if settings.playSounds { SoundEffects.shared.playArm() }
        recorder.start()
        armWarmupWatchdog()
    }

    /// Open the journal file the HUD is currently reporting, if any. Wired to
    /// a click on the HUD's terminal frame.
    @discardableResult
    func openLastJournalFile() -> Bool {
        guard let url = lastJournalURL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Commit whatever recording is in flight, whichever hotkey started it.
    ///
    /// This is the HUD's click-to-stop: the panel already accepts clicks while
    /// the pipeline is cancellable (that's how the ✕ works), so the body of it
    /// may as well be the stop button — the alternative is a HUD you can see
    /// and point at but not use. Only meaningful while `.recording`; the later
    /// stages have nothing to stop, and ✕ still cancels them.
    func commitRecording() {
        guard case .recording = state else { return }
        if inFlightAssistant != nil {
            finishAssistant()
        } else {
            finishRecording()
        }
    }

    /// The journal hotkey's release. Guarded on the in-flight capture
    /// actually being a journal one, so releasing the journal key while an
    /// ordinary dictation is running doesn't commit somebody else's recording.
    func finishJournal() {
        guard inFlight.isJournal else { return }
        finishRecording()
    }

    /// URL of the page in the frontmost browser, for website-bound modes.
    ///
    /// Returns nil — without touching Accessibility at all — unless a mode
    /// actually has a website binding and the front app is a browser. This
    /// runs on the hotkey-press path, which is the one place in this app with
    /// a documented history of main-thread stalls, so the common case has to
    /// cost nothing.
    private func frontmostBrowserURL(bundleID: String?) -> String? {
        guard settings.anyModeHasURLBinding,
              BrowserURLReader.isBrowser(bundleID: bundleID),
              let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        return BrowserURLReader.currentURL(bundleID: bundleID, pid: app.processIdentifier)
    }

    func finishRecording() {
        // If we're recording for Assistant Mode, ignore — the assistant hotkey's
        // release handler owns this recording session.
        guard inFlightAssistant == nil else { return }
        // User released the hotkey before the mic finished warming up. The
        // engine isn't producing buffers yet, so there's nothing to
        // transcribe — abort the startup and return to idle cleanly.
        if case .warmingUp = state {
            recorder.cancelStart()
            state = .idle
            return
        }
        guard case .recording = state else { return }
        let samples = recorder.stop()
        audioInterrupter.stop()
        if settings.playSounds { SoundEffects.shared.playStop() }
        tearDownInterim()
        guard samples.count > 8_000 else { // <0.5s of audio @ 16kHz
            state = .idle
            return
        }
        // Cut the dead air off both ends before the engine ever sees it. Two
        // wins on every push-to-talk clip: less audio to transcribe, and no
        // near-silent frames for Whisper to hallucinate "Thank you." over.
        // Conservative by construction — `SilenceTrimmer` hands back the
        // original whenever trimming would be unsafe.
        var speech = samples
        if settings.trimSilenceEnabled {
            let trimmed = SilenceTrimmer.trim(samples)
            if trimmed.didTrim {
                NSLog("[Dictator] Trimmed %.2fs of silence (%.2fs lead, %.2fs tail) from a %.2fs recording.",
                      trimmed.totalSecondsRemoved, trimmed.leadingSecondsRemoved,
                      trimmed.trailingSecondsRemoved, Double(samples.count) / 16_000)
                speech = trimmed.samples
            }
        }
        inFlight.spokenSeconds = Double(speech.count) / 16_000
        let payload = speech
        inFlightTask = Task { @MainActor [weak self] in
            await self?.runPostCapture(samples: payload)
            self?.inFlightTask = nil
        }
    }

    private func runPostCapture(samples: [Float]) async {
        state = .transcribing
        let raw: String
        do {
            // NOTE: whisperPromptHint is intentionally NOT passed here. Two
            // attempts at biasing Whisper via promptTokens (a wordlist and a
            // natural-sentence form) both pushed the decoder into no-speech
            // rejection on real audio. The TranscriptionService still accepts
            // `prompt:` (preserved on the concrete class only, not the
            // ASREngine protocol) so we can revisit with a different strategy
            // — likely a runtime-detected previous segment, or a much shorter
            // hint — without re-plumbing.
            let watchdog = startTranscribeWatchdog(
                budget: Self.transcribeBudgetSeconds(audioSamples: samples.count)
            )
            defer { watchdog.cancel() }
            let asr = activeASR
            raw = try await asr.engine.transcribe(samples: samples, modelID: asr.modelID,
                                                  language: currentMode.spokenLanguage)
        } catch {
            if Task.isCancelled { return }
            fail("Transcribe: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight.raw = trimmed
        // Empty transcript = Whisper heard nothing (no-speech segment, mic
        // muted, hotkey tap with no audio, …). Surface it in the HUD so the
        // user can tell "didn't hear me" apart from "something broke".
        guard !trimmed.isEmpty else {
            fail("No speech detected")
            return
        }

        // Deterministic spoken-cue substitution runs BEFORE the LLM so every
        // engine (including None) gets emoji + punctuation handling. Small
        // local models — especially Apple Foundation's ~3 B — are unreliable
        // at the cue rules in the formatter prompt, so we don't depend on
        // them. The formatter prompt keeps the rules as a backstop for
        // anything the curated map misses. Per-mode gates pick which cue
        // families run — a mode can keep punctuation on while disabling
        // emojis, or only run currency substitution, etc.
        let cueOptions = spokenCuesOptions(for: currentMode)
        if cueOptions.anyEnabled {
            trimmed = SpokenCues.apply(to: trimmed, options: cueOptions)
        }

        // Fold in window-vision terms (captured concurrently with recording)
        // before any pass or the diacritic restore reads context. Awaited once
        // here so every downstream branch — formatter, the question/no-LLM
        // skips, the delivery-time restore — sees the same merged term list.
        // Normally instant: the capture finished while we were transcribing.
        // When it hasn't, say so rather than leaving "Transcribing…" on screen.
        if inFlight.visionTask != nil, !currentMode.passes.isEmpty { state = .readingScreen(purpose: .spellings) }
        await resolveVisionTerms()

        // The mode's LLM pipeline is the ordered pass list its STYLE resolves to
        // (Raw → none, Clean → Format, Polished → Format + Polish, …), against
        // the current built-in prompts. With no engine (LLM = None) or a raw
        // style, the transcript flows straight through the deterministic
        // vocabulary/diacritic passes and out.
        let llm = currentLLM()
        let passes = (llm == nil) ? [] : currentMode.passes

        var text = trimmed
        var warning: String? = nil
        var deterministicApplied = false

        // The user dictionary + mined document-spelling restore. Deterministic,
        // run ONCE right after the first LLM pass (or immediately, if the mode
        // has none) so later passes see the corrected text — exactly where
        // these sat in the old fixed pipeline (after Pass 1, before grammar).
        func applyDeterministicMidPasses() {
            guard !deterministicApplied else { return }
            deterministicApplied = true
            let before = text
            if currentMode.vocabularyEnabled {
                text = Vocabulary.apply(VocabularyStore.shared.entries, to: text)
            }
            if let context = combinedContext(), !context.documentTerms.isEmpty {
                let restored = DocumentTerms.restoreDiacritics(in: text, terms: context.documentTerms)
                if restored != text {
                    NSLog("[Dictator] Restored document spelling from mined terms.")
                    text = restored
                }
            }
            if text != before { inFlight.dictionaryCorrected = text }
        }

        for (index, pass) in passes.enumerated() {
            if Task.isCancelled { return }
            let isFirst = index == 0
            // The dictionary and the mined document spellings are in the
            // language the user *spoke*. On a Raw mode that only translates,
            // the translation is the first pass, and running them after it
            // would be trying to correct spellings in a language they were
            // never written for.
            if pass.kind == .translate { applyDeterministicMidPasses() }

            // Skip conditions, preserving the old per-pass guards:
            //  • pure emoji/punctuation (no words) — nothing to transform, and
            //    small models narrate instead of echoing;
            //  • question-shaped input, FIRST pass only — Whisper already
            //    punctuates questions and the formatter is tempted to answer.
            let wordsFree = Self.wordSequence(text).isEmpty
            // The question skip exists because the *formatter* is tempted to
            // answer a question instead of punctuating it. A translator has no
            // such excuse — "what time is the meeting?" is exactly as
            // translatable as anything else, and skipping it would silently
            // leave one sentence in the wrong language.
            let questionSkip = isFirst && pass.kind != .translate && Self.looksLikeQuestion(text)
            if wordsFree || questionSkip {
                if isFirst { applyDeterministicMidPasses() }
                continue
            }

            state = Self.hudState(for: pass)

            // The built-in prompt is the base; the mode's extra instructions and
            // the user's global instructions layer on under their own headers.
            // Nothing here is stored on disk — a prompt improvement in code
            // reaches every existing mode on the next launch.
            let prompt = DictatorSettings.assemblePrompt(
                base: pass.prompt,
                extraInstructions: currentMode.extraInstructions,
                global: settings.globalPromptAddendum
            )
            // Surrounding-document context rides on the FIRST pass's prompt only
            // (names/terminology), same as the old Pass 1; the dictation stays
            // the only <<<>>> data block. When that pass is chunked, only chunk
            // 0 gets it — the caret's surroundings describe the start of the
            // dictation, not the middle of it.
            // Document context is terminology in the language the user spoke;
            // hanging it off a translate prompt is noise at best.
            var contextBlock: String? = nil
            if isFirst, pass.kind != .translate, let context = combinedContext(), context.hasPromptMaterial {
                contextBlock = context.formatterPromptBlock
                NSLog("[Dictator] Pass 1 (%@) running with document context (%d/%d chars, %d terms).",
                      pass.name, context.textBefore.count, context.textAfter.count, context.documentTerms.count)
            }

            let produced: String
            do {
                produced = try await runPassPossiblyChunked(
                    pass: pass,
                    text: text,
                    prompt: prompt,
                    contextBlock: contextBlock,
                    echoContext: contextBlock == nil ? nil : inFlight.context,
                    llm: llm!
                )
            } catch {
                // Engine failure (not loaded, etc.) will hit every later pass
                // too — stop here and ship what we have with a note.
                warning = "LLM failed: \(error.localizedDescription)"
                if isFirst { applyDeterministicMidPasses() }
                break
            }

            // `runPassPossiblyChunked` already reverted anything empty or
            // gate-failing, so a text that came back unchanged means the pass
            // contributed nothing and doesn't earn a history stage.
            if produced != text {
                text = produced
                recordStageOutput(pass: pass, isFirst: isFirst, output: produced)
            }

            if isFirst { applyDeterministicMidPasses() }
        }
        // Covers pass-free modes (Raw / LLM None) and the all-skipped case.
        applyDeterministicMidPasses()
        if Task.isCancelled { return }

        // Automatic paragraphing. Runs after every pass so it sees the final
        // wording, and only when nothing upstream already structured the text.
        // Skipped after an engine failure — the next call would fail too.
        if warning == nil, let llm, currentMode.runsAutoParagraphs {
            if let split = await autoParagraph(text: text, llm: llm) {
                text = split
                inFlight.stages.append(DictationStage(name: "Paragraphs", text: split))
                inFlight.restructured = split
            }
        }
        if Task.isCancelled { return }

        let note = warning ?? pendingNote
        pendingNote = nil
        await finish(text: text, warning: note)
    }

    // MARK: - Pass execution

    /// Word count at or above which a pass is split into sentence-bounded
    /// chunks. Long dictations degrade badly in a single call on a 3–4 B model:
    /// the tail gets summarised, truncated, or quietly dropped, and the
    /// whole-text gate then reverts everything — so the user's 400-word
    /// dictation lands completely unformatted. Chunking keeps each call inside
    /// the range these models are reliable in, and localises a gate failure to
    /// the one chunk that misbehaved.
    static let chunkThresholdWords = 250
    /// Target size of each chunk. Comfortably under the threshold so a
    /// just-over-threshold dictation splits into two balanced halves rather
    /// than one full chunk and a stub.
    static let chunkTargetWords = 180

    /// Runs one pass over `text`, chunking it first when it's long enough that a
    /// single call would be unreliable. Chunks run SEQUENTIALLY — there is one
    /// MLX container and one Apple Foundation session; concurrent calls would
    /// serialise anyway, at the cost of holding several KV caches at once.
    ///
    /// Returns the pass's text: accepted chunk outputs where the gate passed,
    /// the chunk's own input where it didn't. Throws only on engine failure.
    private func runPassPossiblyChunked(
        pass: DictationPass,
        text: String,
        prompt: String,
        contextBlock: String?,
        echoContext: InsertionContext?,
        llm: any LLMEngine
    ) async throws -> String {
        let words = DictationText.wordCount(text)
        var pieces = [text]
        if words >= Self.chunkThresholdWords {
            let split = DictationText.chunks(text, targetWords: Self.chunkTargetWords)
            if split.count > 1 {
                pieces = split
                NSLog("[Dictator] Pass '%@': %d words — running as %d sentence-bounded chunks.",
                      pass.name, words, split.count)
            }
        }

        var outputs: [String] = []
        outputs.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let isFirstChunk = index == 0
            var chunkPrompt = prompt
            if isFirstChunk, let contextBlock { chunkPrompt += "\n\n" + contextBlock }
            let chunkOutput = try await runPassChunk(
                pass: pass,
                text: piece,
                prompt: chunkPrompt,
                echoContext: isFirstChunk ? echoContext : nil,
                llm: llm
            )
            outputs.append(chunkOutput)
        }
        return outputs.count == 1 ? outputs[0] : Self.joinChunks(outputs)
    }

    /// One LLM call plus its deterministic post-checks. Returns `text` unchanged
    /// whenever the model's output can't be trusted, so the caller never has to
    /// distinguish "reverted" from "accepted but identical".
    private func runPassChunk(
        pass: DictationPass,
        text: String,
        prompt: String,
        echoContext: InsertionContext?,
        llm: any LLMEngine
    ) async throws -> String {
        // `.interactive` so a meeting generation borrowing the model over the
        // socket is cancelled at the next token rather than making the user
        // wait. Runs inline in this task, so the existing `Task.isCancelled`
        // cancellation story is untouched.
        var candidate = try await LLMScheduler.shared.run(.interactive) {
            try await llm.runPass(text: text, systemPrompt: prompt)
        }

        // Seam-echo guard on the context-bearing chunk: the model sometimes
        // glues the context tail onto the front of its output.
        if let echoContext {
            let stripped = Self.stripContextEcho(candidate, raw: text, context: echoContext)
            if stripped != candidate {
                NSLog("[Dictator] Pass 1 echoed document context at the seam — stripped the echoed words.")
                candidate = stripped
            }
        }

        if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSLog("[Dictator] Pass '%@' returned empty — kept previous text.", pass.name)
            return text
        }
        let inputWords = Self.wordSequence(text).count
        guard Self.passesGate(pass, input: text, output: candidate) else {
            NSLog("[Dictator] Pass '%@' failed its '%@' gate (%d words in) — reverted.",
                  pass.name, Self.gateName(for: pass, inputWords: inputWords), inputWords)
            return text
        }
        return candidate
    }

    /// Re-joins chunk outputs. A single space normally; a blank line when the
    /// preceding chunk's output ended on a newline, because that break was the
    /// model's own paragraph/list boundary and flattening it would undo the one
    /// piece of structure it produced.
    static func joinChunks(_ pieces: [String]) -> String {
        var out = ""
        var separator = ""
        for piece in pieces {
            let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }
            if !out.isEmpty { out += separator }
            out += body
            separator = piece.hasSuffix("\n") ? "\n\n" : " "
        }
        return out
    }

    /// Records an accepted pass output: the ordered `stages` journey the History
    /// pane renders, plus the legacy fixed-pass slot so records written now
    /// still read correctly in a History pane that predates styles.
    private func recordStageOutput(pass: DictationPass, isFirst: Bool, output: String) {
        inFlight.stages.append(DictationStage(name: pass.name, text: output))
        if isFirst {
            inFlight.formatted = output
        } else {
            inFlight.tidied = output
        }
    }

    /// Maps a pass to one of the existing HUD states so the panel keeps a
    /// distinct icon/label per stage without a new enum case: the rewriting
    /// passes read as formatting, Polish as grammar-fixing. (`.restructuring` is
    /// reserved for the automatic paragraph split.)
    static func hudState(for pass: DictationPass) -> PipelineState {
        switch pass.kind {
        case .format, .messages, .custom: return .formatting
        case .polish: return .fixingGrammar
        case .translate: return .translating
        }
    }

    /// Below this many input words the strict content gates are skipped in
    /// favour of the number check alone.
    ///
    /// This is why the gates are back on at all. Applied to short inputs they
    /// false-positived constantly — a six-word dictation has too few anchor
    /// words to measure survival against, and any legitimate filler removal
    /// blows past a drift fraction computed over a handful of tokens — so they
    /// were switched off globally and long dictations lost their only guard.
    /// Length-gating restores the protection exactly where the failure modes
    /// (a summarised or answered dictation) actually occur.
    static let strictGateMinWords = 40

    /// Drift ceiling for the Polish pass: it is *supposed* to remove fillers and
    /// false starts, so the budget is much looser than the old grammar pass's
    /// 0.15 — and the fillers are stripped from both sides before measuring.
    static let polishMaxDriftFraction = 0.30

    /// Runs a pass's deterministic post-check. On `false` the pipeline discards
    /// the pass's output and carries the previous text forward. Number
    /// preservation is folded into every gate because small models like to
    /// prose-ify digits and SpokenCues can't undo that downstream.
    static func passesGate(_ pass: DictationPass, input: String, output: String) -> Bool {
        let inputWords = wordSequence(input).count
        guard inputWords >= strictGateMinWords else {
            return numbersPreserved(input, output)
        }
        switch pass.kind {
        case .format, .messages, .custom:
            // Anchor survival + growth cap: catches the model answering,
            // summarising, or replacing the dictation with commentary.
            return passOnePreservesContent(raw: input, formatted: output)
        case .polish:
            // The combined format-and-polish pass: the format guard (anchors
            // survive, no growth — catches answering and summarising) plus
            // the drift ceiling with fillers stripped (catches rewording).
            guard passOnePreservesContent(raw: input, formatted: output) else { return false }
            return wordEditFractionStrippingFillers(from: input, to: output) <= polishMaxDriftFraction
        case .translate:
            // Every content-preservation check is meaningless here by
            // definition — a translation is *supposed* to share no words with
            // its input. What's left is the length sanity check that catches
            // the two failure modes a translator actually has: answering the
            // text instead of translating it (much longer), and summarising
            // it (much shorter). Numbers still have to survive.
            return translationLooksSane(input: input, output: output)
        }
    }

    /// Name of the gate `passesGate` applies for this pass and input length —
    /// for the revert log line, so a rejection says which check fired.
    static func gateName(for pass: DictationPass, inputWords: Int) -> String {
        guard inputWords >= strictGateMinWords else { return "numbers preserved" }
        switch pass.kind {
        case .format, .messages, .custom: return "content preserved"
        case .polish: return "content preserved + max drift"
        case .translate: return "length + numbers preserved"
        }
    }

    // MARK: - Automatic paragraphing

    /// Word count at or above which a dictation is offered to the paragraph
    /// pass. Below it, one paragraph is the right answer.
    static let autoParagraphMinWords = 60

    /// Splits a long single-paragraph dictation into paragraphs.
    ///
    /// The model never sees or emits prose: it receives a NUMBERED list of the
    /// dictation's sentences and replies with the numbers that should start a
    /// paragraph. The split is then applied by `DictationText`, which only ever
    /// re-joins the sentences we already had — so the result is provably a
    /// whitespace-only change, and a drifting small model cannot rewrite a
    /// single word through this path. The signature check below enforces that
    /// even if the sentence tokeniser misbehaves.
    ///
    /// Returns nil (leave the text alone) for every failure: too short, already
    /// structured, too few sentences, an unusable reply, an engine error.
    private func autoParagraph(text: String, llm: any LLMEngine) async -> String? {
        guard DictationText.wordCount(text) >= Self.autoParagraphMinWords else { return nil }
        // Already structured — the user spoke "new paragraph", or a pass broke
        // it up. That structure is theirs; don't second-guess it.
        guard !text.contains("\n\n") else { return nil }
        let sentences = DictationText.sentences(text)
        guard sentences.count >= 3 else { return nil }

        state = .restructuring
        let numbered = sentences.enumerated()
            .map { "[\($0.offset + 1)] \($0.element)" }
            .joined(separator: "\n")

        let reply: String
        do {
            // 48 tokens is generous for a list of at most a few dozen numbers,
            // and tight enough that a model that starts writing prose instead
            // gets cut off long before it costs anything.
            reply = try await LLMScheduler.shared.run(.interactive) {
                try await llm.complete(
                    system: DictatorSettings.builtinParagraphsPrompt,
                    user: numbered,
                    maxTokens: 48
                )
            }
        } catch {
            NSLog("[Dictator] Auto-paragraph pass failed (%@) — left as one paragraph.",
                  error.localizedDescription)
            return nil
        }
        if Task.isCancelled { return nil }

        let starts = DictationText.parseParagraphStarts(reply, sentenceCount: sentences.count)
        // "none", a refusal, or anything without usable numbers.
        guard !starts.isEmpty else { return nil }
        // More than half the sentences starting a paragraph isn't paragraphing,
        // it's a line break after every thought — the model misread the task.
        guard starts.count <= sentences.count / 2 else {
            NSLog("[Dictator] Auto-paragraph: %d breaks for %d sentences — rejected as over-splitting.",
                  starts.count, sentences.count)
            return nil
        }

        let split = DictationText.applyParagraphStarts(sentences, starts)
        guard split != text else { return nil }
        // Belt and braces on the whitespace-only guarantee: if the sentence
        // tokeniser dropped or reordered anything, ship the original.
        guard DictationText.nonWhitespaceSignature(split)
                == DictationText.nonWhitespaceSignature(text) else {
            NSLog("[Dictator] Auto-paragraph: re-join changed the text — kept one paragraph.")
            return nil
        }
        NSLog("[Dictator] Auto-paragraphs: %d sentences → %d paragraphs.",
              sentences.count, starts.count + 1)
        return split
    }

    /// Drift measure used by the Polish gate. We strip known speech fillers
    /// and articles from BOTH sides before computing Levenshtein, so the
    /// validator doesn't punish the model for dropping ums, false starts, or
    /// adding/removing articles — those are the changes we want it to make.
    /// What's still measured: substantive substitutions and additions of
    /// content words, which is where actual hallucination would show up.
    private static func wordEditFractionStrippingFillers(from a: String, to b: String) -> Double {
        // Date ordinals are canonicalised to their spoken words on both sides
        // first, so "the twenty first" → "the 21st" costs nothing here either.
        let aw = DateOrdinals.canonicalised(wordSequence(a))
            .filter { !grammarFillerStripSet.contains($0) }
        let bw = DateOrdinals.canonicalised(wordSequence(b))
            .filter { !grammarFillerStripSet.contains($0) }
        let n = max(aw.count, bw.count)
        guard n > 0 else { return 0 }
        return Double(wordLevenshtein(aw, bw)) / Double(n)
    }

    /// Single-word fillers that the tighten validator ignores on both sides.
    /// Intentionally lenient — the goal is to not REJECT legitimate filler
    /// removal, not to require it. The model isn't told this list; it's just
    /// a safety relaxation. Multi-word fillers ("you know", "I mean") aren't
    /// here because their components are normal words elsewhere — they'll
    /// usually drop out via Levenshtein's deletion cost staying under the
    /// 0.30 ceiling.
    private static let grammarFillerStripSet: Set<String> = [
        "um", "umm", "uh", "uhh", "ah", "ahh", "er", "erm", "ehm",
        "hmm", "mm", "mhm",
        "like", "well", "basically", "literally", "actually",
        "just", "really", "so",
        "a", "an", "the",
    ]

    private static func wordLevenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    /// Returns the input as a sequence of lowercased alphanumeric "words" — the
    /// common currency of every content gate (length, anchors, drift) and of the
    /// "is there anything here to transform?" skip check.
    private static func wordSequence(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Multiset (sorted, lowercased) of the number-bearing tokens in `text`:
    /// digit runs, decimals, and digit-led forms like "4x" or "10:30pm". By the
    /// time the grammar/structure passes run, all number formatting is already
    /// fixed (Parakeet's output plus SpokenCues plus Pass 1), so this is a
    /// stable fingerprint of "the numbers in this text".
    private static func numberSignature(_ text: String) -> [String] {
        guard let regex = try? Regex("[0-9][0-9.,]*[A-Za-z]*") else { return [] }
        return text.matches(of: regex)
            // Trailing dots and commas belong to the sentence, not the number:
            // the character class has to admit them for "1,600" and "2.5", and
            // then swallows the punctuation in "at 10." as well. Left in, the
            // gate saw "10" become "10." and reverted the pass — so a short
            // dictation ending in a number lost its formatting to the full stop
            // the formatter had just correctly added.
            .map { String(text[$0.range]).lowercased()
                    .replacing(/[.,]+$/, with: "") }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// True when `after` carries the same numbers as `before`. Used to gate the
    /// content-preserving passes: small local models like to "prose-ify"
    /// numbers — spelling "4x" out to "four times", "3" to "three" — and
    /// SpokenCues can't undo that afterwards (the word "times" is ambiguous and
    /// bare word-numbers are deliberately never re-digitised).
    /// Arithmetic/currency the formatter applied stays stable here because the
    /// digit tokens survive ("5 plus 3" → "5 + 3" keeps {3, 5}).
    ///
    /// The one asymmetry: a spoken day ordinal is allowed to ARRIVE as digits.
    /// Writing "on the second" as "on the 2nd" is a change only the model can
    /// make — whether an ordinal is a date depends on the sentence, not on any
    /// pattern we could match — so an exact-signature gate would revert every
    /// dictated date the formatter got right. `DateOrdinals` bounds the licence
    /// tightly: only ordinals the input actually spoke, only as many as it
    /// spoke, and never the other way round. Digits that turn back into words
    /// still fail, which is what this gate was built for.
    private static func numbersPreserved(_ before: String, _ after: String) -> Bool {
        DateOrdinals.signaturesMatch(
            before: numberSignature(before),
            after: numberSignature(after),
            promotable: DateOrdinals.promotableOrdinals(in: wordSequence(before))
        )
    }

    /// Detects the common failure where Pass 1 answers the user's question instead
    /// of transcribing it. Two checks, both must pass:
    ///
    /// 1. **Length**: the formatter never *adds* content words. If the output is
    ///    materially longer than the input (more than +3 words and more than 1.15× the
    ///    input word count), the model elaborated — almost always because it answered
    ///    the question. This catches the failure mode the anchor check is blind to:
    ///    answers that quote the question back ("The formatter returns empty
    ///    because…") still hit all the anchors but expand the output.
    ///
    /// 2. **Anchors**: ≥60% of the input's content words (≥4 chars, not in our spoken-
    ///    punctuation trigger vocabulary) must survive in the output. Short inputs
    ///    (<3 anchors) skip this — too few signals to discriminate cleanly (e.g.
    ///    "fire emoji" → "🔥" has zero anchor survival but is correct).
    static func passOnePreservesContent(raw: String, formatted: String) -> Bool {
        let rawWords = wordSequence(raw)
        let fmtWords = wordSequence(formatted)

        // Length check. Allow small additions (contractions split, etc.) but reject
        // anything that visibly expands — that's the model writing an answer.
        let maxAllowed = max(rawWords.count + 3, Int(ceil(Double(rawWords.count) * 1.15)))
        if fmtWords.count > maxAllowed { return false }

        let anchors = anchorWords(raw)
        guard anchors.count >= 3 else { return true }
        // The output's words, plus the spoken form of any date ordinal in it:
        // a "second" that came back as "2nd" has survived, not vanished. On a
        // short dictation like "free from the second to the fourth" that's two
        // of four anchors, which alone would fail the check.
        let outputSet = DateOrdinals.anchorSet(fmtWords)
        let hits = anchors.filter { outputSet.contains($0) }
        return Double(hits.count) / Double(anchors.count) >= 0.6
    }

    /// Awaits the in-flight window-vision capture and stashes its terms.
    /// Called once, after transcription — by which point the capture (started
    /// at hotkey press) has almost always finished, so this returns instantly;
    /// the worst case is bounded by `WindowVisionContext`'s own deadline.
    /// Post-check for the Translate pass.
    ///
    /// Nothing the other gates measure applies: a translation legitimately
    /// shares no anchor words with its input, so `passOnePreservesContent`
    /// would reject every correct result. What a translation *can't* do is
    /// change size dramatically — real language pairs run roughly 0.6× to
    /// 1.8× the source word count, with the extremes being compact→verbose
    /// pairs like English→French. Outside that band the model has either
    /// answered the text or summarised it, which are the two ways this pass
    /// actually fails. Digits still have to survive.
    static func translationLooksSane(input: String, output: String) -> Bool {
        let inputWords = wordSequence(input).count
        let outputWords = wordSequence(output).count
        guard inputWords > 0, outputWords > 0 else { return false }
        let ratio = Double(outputWords) / Double(inputWords)
        // The +4 floor keeps a five-word dictation from failing on a single
        // extra article, where the ratio is a very blunt instrument.
        guard outputWords <= Int(Double(inputWords) * 1.8) + 4 else { return false }
        guard ratio >= 0.5 || outputWords >= inputWords - 4 else { return false }
        return numbersPreserved(input, output)
    }

    private func resolveVisionTerms() async {
        guard let task = inFlight.visionTask else { return }
        inFlight.visionTask = nil
        // The mode can change after the capture was kicked off — the user
        // cycles to Quick mid-sentence. With no LLM pass left to feed, the
        // terms have no destination, so drop the task rather than stand here
        // waiting on an inference whose result goes in the bin.
        guard !currentMode.passes.isEmpty else {
            task.cancel()
            inFlight.visionAttempted = false
            return
        }
        // The number that decides whether the overlap is working. Near zero
        // means the read finished while the user was still speaking and the
        // HUD stage was a flicker; seconds means the pipeline genuinely stood
        // still, and the `[Vision]` lines above say which part was slow.
        let waitStart = CFAbsoluteTimeGetCurrent()
        inFlight.visionTerms = await task.value
        let now = CFAbsoluteTimeGetCurrent()
        VisionLog.log(String(format: "pipeline WAITED %.2fs (read began %.2fs before this point, %d term(s))",
                             now - waitStart, waitStart - inFlight.visionStartedAt,
                             inFlight.visionTerms.count))
    }

    /// The Accessibility context merged with any window-vision terms. Vision is
    /// purely additive — it only contributes spelling-reference terms — so when
    /// AX read nothing but vision did (an Electron/canvas/terminal app, or names
    /// outside the field), we synthesise a terms-only context so those terms
    /// still reach the formatter prompt and the diacritic restore. Returns nil
    /// only when neither source produced anything. AX terms keep priority (the
    /// document the user is in is the most authoritative source); vision fills
    /// in behind them, deduped case-insensitively and capped so the prompt's
    /// term list can't balloon on a busy screen.
    private func combinedContext() -> InsertionContext? {
        let visionTerms = inFlight.visionTerms
        guard let ax = inFlight.context else {
            return visionTerms.isEmpty
                ? nil
                : InsertionContext(textBefore: "", textAfter: "", documentTerms: visionTerms)
        }
        guard !visionTerms.isEmpty else { return ax }
        var merged = ax.documentTerms
        var seen = Set(merged.map { $0.lowercased() })
        for term in visionTerms where seen.insert(term.lowercased()).inserted {
            merged.append(term)
        }
        return InsertionContext(
            textBefore: ax.textBefore,
            textAfter: ax.textAfter,
            documentTerms: Array(merged.prefix(Self.maxCombinedTerms))
        )
    }

    /// Ceiling on the merged AX + vision term list. Comfortably above either
    /// source's own cap so both contribute, but bounded so a text-dense window
    /// doesn't stuff the small model's prompt.
    private static let maxCombinedTerms = 40

    /// The assistant's AX context merged with a window-vision read-back. Vision
    /// is additive: its mined terms join the AX terms, and its visible-text
    /// read-back becomes the [SCREEN] block. When AX read nothing but vision did
    /// (an AX-blind app), a context is synthesised from the vision data alone.
    /// Returns nil only when neither source produced anything.
    private func assistantContextMerging(_ readback: WindowVisionContext.VisionReadback) -> InsertionContext? {
        let base = inFlightAssistant?.context
        guard !readback.content.isEmpty || !readback.terms.isEmpty else { return base }
        var merged = base?.documentTerms ?? []
        var seen = Set(merged.map { $0.lowercased() })
        for term in readback.terms where seen.insert(term.lowercased()).inserted {
            merged.append(term)
        }
        return InsertionContext(
            textBefore: base?.textBefore ?? "",
            textAfter: base?.textAfter ?? "",
            documentTerms: Array(merged.prefix(Self.maxCombinedTerms)),
            screenContent: readback.content
        )
    }

    /// Removes words Pass 1 glued on from the surrounding-document context.
    /// Small models shown the text before the caret sometimes "complete the
    /// seam": they prepend the tail of the context to the dictation
    /// ("I think we " + "should go" → "we should go"), or append the head of
    /// the after-context. Deterministic detector: leading output words that
    /// match the context tail in order — and are NOT how the raw transcript
    /// starts — came from the context, not the speaker. Mirror logic for the
    /// suffix. Stripping everything (output was pure echo) is fine: the
    /// empty-output fallback upstream then reverts to the raw transcript.
    static func stripContextEcho(_ formatted: String, raw: String, context: InsertionContext) -> String {
        let maxEchoWords = 8
        var result = formatted
        let rawWords = wordSequence(raw)

        let beforeTail = Array(wordSequence(context.textBefore).suffix(maxEchoWords))
        if !beforeTail.isEmpty {
            let outWords = wordSequence(result)
            var j = min(beforeTail.count, outWords.count)
            while j > 0 {
                if Array(outWords.prefix(j)) == Array(beforeTail.suffix(j)),
                   Array(rawWords.prefix(j)) != Array(outWords.prefix(j)) {
                    result = dropWords(result, fromFront: j)
                    break
                }
                j -= 1
            }
        }

        let afterHead = Array(wordSequence(context.textAfter).prefix(maxEchoWords))
        if !afterHead.isEmpty {
            let outWords = wordSequence(result)
            var j = min(afterHead.count, outWords.count)
            while j > 0 {
                if Array(outWords.suffix(j)) == Array(afterHead.prefix(j)),
                   Array(rawWords.suffix(j)) != Array(outWords.suffix(j)) {
                    result = dropWords(result, fromBack: j)
                    break
                }
                j -= 1
            }
        }
        return result
    }

    /// Drops the first `count` words (and the separators around them) from `s`.
    /// Word boundaries match `wordSequence`'s definition (letter/number runs)
    /// so counts line up with the echo detector above.
    private static func dropWords(_ s: String, fromFront count: Int) -> String {
        guard count > 0 else { return s }
        var dropped = 0
        var inWord = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let isWordChar = s[idx].isLetter || s[idx].isNumber
            if isWordChar, !inWord {
                inWord = true
                if dropped == count { return String(s[idx...]) }
            } else if !isWordChar, inWord {
                inWord = false
                dropped += 1
            }
            idx = s.index(after: idx)
        }
        return ""
    }

    /// Drops the last `count` words (and the separators around them) from `s`.
    private static func dropWords(_ s: String, fromBack count: Int) -> String {
        guard count > 0 else { return s }
        var dropped = 0
        var inWord = false
        var idx = s.endIndex
        while idx > s.startIndex {
            let prev = s.index(before: idx)
            let isWordChar = s[prev].isLetter || s[prev].isNumber
            if isWordChar, !inWord {
                inWord = true
                if dropped == count { return String(s[..<idx]) }
            } else if !isWordChar, inWord {
                inWord = false
                dropped += 1
            }
            idx = prev
        }
        return ""
    }

    private static let passOneTriggerWords: Set<String> = [
        "comma", "period", "stop", "question", "mark", "exclamation", "point",
        "colon", "semicolon", "paren", "parens", "dash", "quote", "quotes",
        "emoji", "line", "newline", "paragraph", "open", "close"
    ]

    private static func anchorWords(_ s: String) -> [String] {
        wordSequence(s).filter { word in
            word.count >= 4 && !passOneTriggerWords.contains(word)
        }
    }

    /// Heuristic for question-shaped input. When true we bypass the formatter pass
    /// to avoid the "model answers instead of transcribes" failure. Triggers on a
    /// trailing "?" (the strongest signal — Whisper already gave us one) or a
    /// classic interrogative first word ("why", "how", "what", ...). False positives
    /// just lose minor punctuation polish; we trust Whisper's already-capitalised,
    /// already-punctuated output.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let firstWord = trimmed.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map(String.init) ?? ""
        return questionStarters.contains(firstWord)
    }

    private static let questionStarters: Set<String> = [
        "why", "how", "what", "who", "when", "where", "which"
    ]

    /// Project the mode's five spoken-cue toggles onto the struct
    /// SpokenCues consumes. Kept here (rather than as a convenience init
    /// on `SpokenCues.Options`) so SpokenCues itself stays unaware of
    /// `DictationMode`.
    private func spokenCuesOptions(for mode: DictationMode) -> SpokenCues.Options {
        SpokenCues.Options(
            punctuation: mode.punctuationCuesEnabled,
            numbers: mode.numberCuesEnabled,
            times: mode.timeCuesEnabled,
            currency: mode.currencyCuesEnabled,
            emojis: mode.emojiCuesEnabled
        )
    }

    /// Ensures the delivered text ends with a single trailing whitespace so that
    /// continuing to type (or starting another dictation right after) doesn't glue
    /// the next character onto the end of this chunk. No-op if the text already
    /// ends in whitespace (e.g. a structural pass that ended with a newline).
    static func withTrailingSpace(_ s: String) -> String {
        guard let last = s.last, !last.isWhitespace else { return s }
        return s + " "
    }

    /// Drop the auto-capitalisation and trailing period when the user has
    /// dictated something short — a chat reply. Applied only in the Messages
    /// style, and only when no caret snapshot is available (with one, the
    /// context-aware joiner decides). The threshold (≤ 6 words) is calibrated to catch
    /// single-utterance messages without catching anything that reads like
    /// a complete formal sentence. Skipped when the text contains a
    /// strong sentence break ("." mid-text, "?" or "!" anywhere), since
    /// those signal the user is dictating multiple sentences. The first
    /// word is left untouched if it starts with "I" / "I'…" so the
    /// pronoun keeps its proper case.
    static func relaxShortMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 6 else { return text }
        // Internal "." or any "?"/"!" → formal multi-sentence content;
        // leave alone. `dropLast` ignores a single trailing period when
        // checking for an *internal* one.
        let body = trimmed.dropLast()
        if body.contains(".") || trimmed.contains("?") || trimmed.contains("!") {
            return text
        }
        var result = trimmed
        // Strip a single trailing period, but not an ellipsis ("...").
        if result.hasSuffix(".") && !result.hasSuffix("..") {
            result = String(result.dropLast())
        }
        // Lowercase the first letter unless the first word is "I" or a
        // contraction like "I'm", "I'll", "I've", "I'd".
        let firstWord = result
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let isIWord = firstWord == "I" || firstWord.hasPrefix("I'") || firstWord.hasPrefix("I’")
        if !isIWord, let firstChar = result.first, firstChar.isUppercase {
            result = String(firstChar).lowercased() + result.dropFirst()
        }
        // Restore the original trailing whitespace/newline so the
        // delivery path's `withTrailingSpace` stays a no-op when we
        // already had one (and doesn't need to know we touched anything).
        if let lastChar = text.last, lastChar.isWhitespace, !result.hasSuffix(String(lastChar)) {
            result.append(lastChar)
        }
        return result
    }

    private func finish(text: String, warning: String?) async {
        // Trailing space so the next dictation/keystroke doesn't glue itself to this
        // chunk. Particularly important when piping dictation straight into chat apps
        // (Claude, Slack, …) where back-to-back dictations would otherwise mash.
        var text = text
        let cueOptions = spokenCuesOptions(for: currentMode)
        if cueOptions.anyEnabled {
            // Re-apply SpokenCues after the LLM pass. The formatter
            // prompt forbids it, but small local models still sometimes
            // revert substitutions — most visibly the unary "+44" being
            // rewritten back to "Plus 44". apply() is idempotent, so
            // re-running on text that's already clean is a no-op.
            text = SpokenCues.apply(to: text, options: cueOptions)
        }
        if cueOptions.emojis {
            // Strip LLM-introduced separators between adjacent emojis
            // ("🔥, 🎉" → "🔥 🎉"). Apple Foundation in particular tends to
            // list-format substituted emojis. Gated by the emoji toggle
            // specifically — punctuation/numbers/etc. can be off without
            // skipping this cleanup.
            text = SpokenCues.tidyDelivery(text)
        }
        // Re-apply document-spelling restoration after the LLM passes, same
        // rationale as the SpokenCues re-apply above: the grammar pass can
        // quietly strip an accent the earlier restoration put back, and its
        // edit-distance validator won't blink at a one-word diacritic
        // change. Idempotent.
        if let context = combinedContext(), !context.documentTerms.isEmpty {
            text = DocumentTerms.restoreDiacritics(in: text, terms: context.documentTerms)
        }
        // Context-aware join: with a fresh snapshot of the caret's
        // surroundings (taken now, not at press time, so it matches the
        // exact spot the paste lands), spacing, the first word's casing, and
        // the trailing full stop adapt to the insertion point. Falls back to
        // the context-free heuristics when no snapshot is available (mode
        // opted out, paste-automatically off, Accessibility missing, or the
        // focused element doesn't expose ranged text).
        var joinContext: InsertionContext?
        var joinPlaceholderChars = 0
        if currentMode.contextAwarenessEnabled && settings.pasteAutomatically && !inFlight.isJournal {
            let captured = await Task.detached(priority: .userInitiated) {
                AXContextReader.captureDetailed(
                    maxBefore: AXContextReader.joinBeforeCap,
                    maxAfter: AXContextReader.joinAfterCap,
                    requireFieldAccurate: true
                )
            }.value
            joinContext = captured.context
            joinPlaceholderChars = captured.placeholderChars
        }
        // Any successful capture — including an empty-but-readable field —
        // goes through the joiner. An empty field is the clearest start of a
        // sentence, and the joiner handles empty before/after correctly
        // (`isMidSentence("")` is false, so a short dictation keeps its
        // capital, and it still appends a trailing space). Only a genuine
        // capture failure (`nil`: Accessibility missing, no focused element,
        // unreadable field, timeout) falls back to the length heuristic.
        if let joinContext {
            let joined = InsertionJoiner.adjust(text, before: joinContext.textBefore, after: joinContext.textAfter)
            NSLog("[Dictator] Join: caret snapshot (%d/%d chars, %d placeholder chars dropped) in %@ — %@.",
                  joinContext.textBefore.count, joinContext.textAfter.count, joinPlaceholderChars,
                  inFlight.appBundleID ?? "an unknown app",
                  joined == text ? "no adjustment needed" : "adjusted")
            text = joined
        } else {
            NSLog("[Dictator] Join: no caret snapshot — context-free heuristics.")
            // The short-message relax (lowercase the first letter and drop the
            // full stop on a ≤6-word dictation) is a chat-reply convention, so
            // it only applies in the Messages style. Everywhere else a short
            // sentence in a terminal or browser is still a sentence — the
            // no-snapshot path used to lowercase "That looks like it solved it".
            if currentMode.style == .messages {
                text = Self.relaxShortMessage(text)
            }
            text = Self.withTrailingSpace(text)
        }
        // Per-mode override: guarantee a trailing space even when the
        // context-aware joiner decided against one (caret at the end of a
        // terminal/chat line, nothing after it). Lets back-to-back dictation
        // flow without manually typing a leading space. Idempotent with the
        // else-branch call above.
        if currentMode.appendTrailingSpace {
            text = Self.withTrailingSpace(text)
        }
        lastResult = text
        var pasted = false
        var note: String? = warning
        lastDeliveryWasJournal = inFlight.isJournal
        lastJournalURL = nil

        if inFlight.isJournal {
            // Journal entries never touch the frontmost app, and never touch
            // the clipboard either — the whole point is to capture a thought
            // without disturbing whatever you were doing.
            do {
                let written = try JournalWriter.append(
                    text: text,
                    pathTemplate: settings.journalPathTemplate,
                    headerTemplate: settings.journalHeaderTemplate,
                    entryTemplate: settings.journalEntryTemplate,
                    appName: NSWorkspace.shared.frontmostApplication?.localizedName
                )
                lastJournalURL = written.url
                note = warning ?? (written.createdFile
                    ? "Started \(written.url.lastPathComponent) — click to open"
                    : "Added to \(written.url.lastPathComponent) — click to open")
            } catch {
                // Fall back to the clipboard rather than losing the dictation:
                // a mistyped path template shouldn't cost the user their words.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                note = "Couldn't write the journal (\(error.localizedDescription)) — copied to the clipboard instead."
                lastDeliveryWasJournal = false
            }
        } else if settings.pasteAutomatically {
            switch injector.deliver(text: text, pressReturnAfter: currentMode.pressReturnAfterPaste) {
            case .pasted:
                pasted = true
            case .copiedOnly(let reason):
                pasted = false
                note = reason
            }
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // Snapshot the entire dictation into history before flipping to .done.
        let record = DictationRecord(
            id: UUID(),
            timestamp: Date(),
            raw: inFlight.raw,
            style: currentMode.style.label,
            stages: inFlight.stages.isEmpty ? nil : inFlight.stages,
            formatted: inFlight.formatted,
            dictionaryCorrected: inFlight.dictionaryCorrected,
            tidied: inFlight.tidied,
            restructured: inFlight.restructured,
            final: text,
            pasted: pasted,
            inputDevice: AudioDeviceManager.shared.activeInputDeviceName(),
            note: note,
            appBundleID: inFlight.appBundleID,
            deliveredToJournal: lastDeliveryWasJournal,
            visionTermCount: inFlight.visionAttempted ? inFlight.visionTerms.count : nil
        )
        DictationHistory.shared.append(record)
        UsageStatsStore.shared.record(
            mode: .dictation,
            wordsIn: UsageStatsStore.wordCount(inFlight.raw),
            wordsOut: UsageStatsStore.wordCount(text),
            spokenSeconds: inFlight.spokenSeconds
        )
        // Start watching for hand-corrections to what we just pasted. Only
        // for text that actually landed in an app — a journal entry or a
        // clipboard fallback has no field to re-read.
        if settings.learnFromCorrectionsEnabled, pasted, !inFlight.isJournal {
            CorrectionWatcher.shared.watch(delivered: text, appBundleID: inFlight.appBundleID)
        }
        inFlight = InFlight()

        state = .done(text: text, pasted: pasted, note: note)
        if settings.playSounds { SoundEffects.shared.playDone() }
        // Hold the HUD longer when there's something for the user to read —
        // and longer still for a journal entry, which is both the one result
        // the user can't see land anywhere on screen and the one that offers
        // a click (opening the file) they need time to take.
        let lingerMs: Int
        if lastJournalURL != nil {
            lingerMs = 7000
        } else {
            lingerMs = note == nil ? 1400 : 4000
        }
        doneFader = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(lingerMs))
            guard !Task.isCancelled else { return }
            self?.state = .idle
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        doneFader = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.state = .idle
        }
    }

    // MARK: - Assistant Mode

    /// Entry point for the Assistant Mode hotkey press. Grabs the current selection
    /// (synchronously enough that the user holding the hotkey still feels responsive),
    /// then starts the recorder so the user can dictate their instruction.
    func startAssistant() {
        switch state {
        case .done, .failed:
            doneFader?.cancel()
            doneFader = nil
            state = .idle
        default:
            break
        }
        guard case .idle = state else { return }
        guard settings.llmEngine != .none else {
            fail("Assistant Mode needs an LLM. Pick one in Settings → Models.")
            return
        }
        state = .capturingSelection
        // Reset the early-release flag for this attempt — leftover `true`
        // from a prior aborted setup would silently swallow this press.
        assistantReleasePending = false
        Task { [weak self] in
            guard let self else { return }
            do {
                // Selection is optional — Assistant Mode also handles "insert here"
                // style requests where the user has no selection (e.g. "make me a
                // list of ten ideas here please").
                let selection = try await SelectionGrabber.grab()
                // User released before selection-grab finished. Don't start
                // the recorder — just return to idle. Without this the
                // engine starts with no release path queued and the
                // pipeline gets stuck in `.recording` indefinitely.
                if self.assistantReleasePending {
                    self.assistantReleasePending = false
                    self.state = .idle
                    return
                }
                let continues = self.shouldContinueConversation(selection: selection)
                self.nextAssistantIsContinuation = continues
                inFlightAssistant = InFlightAssistant(selection: selection, continuesConversation: continues)
                // Snapshot the document around the selection while focus is
                // still in the target app (the HUD is non-activating). Same
                // Accessibility read dictation uses; always on for the
                // assistant. Detached so a busy app can't stall setup — it
                // lands well before the assist call (transcription buys time),
                // and the >0.5 s audio gate guarantees it has finished. A nil
                // capture (no permission, app hides its text, secure field)
                // just means no context this turn — opportunistic, never
                // load-bearing.
                Task.detached(priority: .userInitiated) { [weak self] in
                    let captured = AXContextReader.captureDetailed(
                        maxBefore: AXContextReader.promptBeforeCap,
                        maxAfter: AXContextReader.promptAfterCap,
                        mineTerms: true
                    )
                    await MainActor.run {
                        self?.inFlightAssistant?.context = captured.context
                        self?.inFlightAssistant?.contextReason = captured.reason
                    }
                }
                // Window-vision context for the assistant: one on-device snapshot
                // of the focused window, read back so the assistant can act on
                // what's on screen ("reply to this") and spell what it sees, even
                // in apps Accessibility can't read. Runs concurrently with the
                // instruction recording; resolved in runAssistantPipeline. Gated
                // on the opt-in + vision support + Screen Recording.
                if settings.visionContextEnabled,
                   WindowVisionContext.isSupported,
                   ScreenRecordingPermission.hasAccess() {
                    // When the assistant's own engine is the vision model, skip
                    // the describe-the-screen pass and let it read the
                    // screenshot during the answer itself. Only the pipeline
                    // knows which engine will answer, so the decision is made
                    // here rather than inside WindowVisionContext.
                    // Either engine can now take the screenshot directly:
                    // a vision-capable MLX model, or Apple's system model on
                    // macOS 27. Both skip the describe-it-to-ourselves pass.
                    let assistantCanSee: Bool
                    switch settings.llmEngine {
                    case .mlx:   assistantCanSee = MLXLLMServiceHolder.shared.canReadImages
                    case .apple: assistantCanSee = WindowVisionContext.appleCanSee
                    case .none:  assistantCanSee = false
                    }
                    inFlightAssistant?.visionTask = Task.detached(priority: .userInitiated) {
                        await WindowVisionContext.captureForAssistant(assistantCanSee: assistantCanSee)
                    }
                }
                // Same async-warmup story as `startRecording`: recorder
                // start is non-blocking so BT HFP negotiation doesn't
                // stall the assistant flow. handleRecorderReady promotes
                // `.warmingUp(kind: .assistant)` to `.recording(...)`.
                state = .warmingUp(kind: .assistant)
                if settings.playSounds { SoundEffects.shared.playArm() }
                recorder.start()
                armWarmupWatchdog()
            } catch SelectionGrabber.GrabError.noAccessibility {
                // If the user released during the failed grab, drop the
                // error — they've already given up on this press, surfacing
                // a permission alert now would be confusing.
                if self.assistantReleasePending {
                    self.assistantReleasePending = false
                    self.state = .idle
                } else {
                    fail("Accessibility permission required for Assistant Mode.")
                }
            } catch {
                if self.assistantReleasePending {
                    self.assistantReleasePending = false
                    self.state = .idle
                } else {
                    fail("Assistant: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Decides whether the next assistant invocation should be a follow-up
    /// against `activeThread`. Two paths in:
    ///
    /// 1. The result window is currently visible AND is displaying the active
    ///    thread. The user is clearly continuing the on-screen conversation.
    /// 2. The user has a selection that overlaps the active thread's last
    ///    reply (i.e. they've kept the previous output selected in their
    ///    editor and triggered Assistant again). Forgiving substring match —
    ///    accommodates light editing on either side.
    ///
    /// Anything else → fresh thread.
    private func shouldContinueConversation(selection: String?) -> Bool {
        guard let active = activeThread else { return false }
        if resultWindowIsVisible?() == true, resultWindowThreadID?() == active.id {
            return true
        }
        guard let selection, let lastReply = active.lastAssistantReply else { return false }
        return Self.selectionMatchesReply(selection: selection, reply: lastReply)
    }

    /// Forgiving overlap check: trimmed selection contained in the last reply,
    /// or vice versa. The 8-character minimum keeps tiny selections ("yes",
    /// "ok") from accidentally triggering continuation against a long reply
    /// that happens to contain them.
    static func selectionMatchesReply(selection: String, reply: String) -> Bool {
        let trimSel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimRep = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimSel.count >= 8 else { return false }
        return trimRep.contains(trimSel) || trimSel.contains(trimRep)
    }

    /// Called when the result window closes. Clears the follow-up state so the
    /// next assistant call starts fresh.
    func endActiveConversation() {
        activeThreadID = nil
        nextAssistantIsContinuation = false
    }

    /// Called when the user reopens a past thread. The next assistant call will
    /// continue it (subject to the usual window-visible / selection-match
    /// triggers).
    func setActiveThread(id: UUID) {
        activeThreadID = id
    }

    /// User-initiated abort, triggered from the HUD's hover cancel button.
    /// Handles every non-idle state:
    ///   - recording: stops the recorder and discards the buffer
    ///   - thinking states: cancels the in-flight Task. LLM generation sees
    ///     this via its didGenerate cancellation closure and stops at the
    ///     next token; the awaiting pipeline code checks `Task.isCancelled`
    ///     after each await and bails before delivery.
    func cancelInFlight() {
        if case .recording = state {
            _ = recorder.stop()
            if settings.playSounds { SoundEffects.shared.playStop() }
        } else if case .warmingUp = state {
            recorder.cancelStart()
        }
        // Idempotent — start() only engages from .recording, so this is a
        // no-op on the .warmingUp branch but a real restore on .recording.
        audioInterrupter.stop()
        tearDownInterim()
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightAssistant = nil
        nextAssistantIsContinuation = false
        pendingNote = nil
        doneFader?.cancel()
        doneFader = nil
        state = .idle
    }

    /// Entry point for the Assistant Mode hotkey release. If the press succeeded in
    /// grabbing a selection and starting the recorder, this runs Whisper on the
    /// dictated instruction and then calls the assistant LLM.
    func finishAssistant() {
        // Release fired while `startAssistant`'s setup task is still
        // awaiting the selection grab. Mark the press for abort — the
        // setup task checks this flag after its await and bails to .idle
        // instead of starting the recorder.
        if case .capturingSelection = state {
            assistantReleasePending = true
            return
        }
        // Release fired while the mic was still warming up (likely
        // Bluetooth). Abort the startup and return to idle without
        // attempting a transcribe — no audio was captured.
        if case .warmingUp = state {
            recorder.cancelStart()
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            state = .idle
            return
        }
        guard let inflight = inFlightAssistant else {
            // Press path failed (no selection, no AX permission, etc.) — release is a no-op.
            return
        }
        guard case .recording = state else { return }
        let samples = recorder.stop()
        audioInterrupter.stop()
        if settings.playSounds { SoundEffects.shared.playStop() }
        guard samples.count > 8_000 else {
            inFlightAssistant = nil
            state = .idle
            return
        }
        let capturedSelection = inflight.selection
        inFlightTask = Task { @MainActor [weak self] in
            await self?.runAssistantPipeline(samples: samples, selection: capturedSelection)
            self?.inFlightTask = nil
        }
    }

    private func runAssistantPipeline(samples: [Float], selection: String?) async {
        let inflight = inFlightAssistant
        let continues = inflight?.continuesConversation ?? false

        state = .transcribing
        let instructionRaw: String
        do {
            let asr = activeASR
            let watchdog = startTranscribeWatchdog(
                budget: Self.transcribeBudgetSeconds(audioSamples: samples.count)
            )
            defer { watchdog.cancel() }
            instructionRaw = try await asr.engine.transcribe(samples: samples, modelID: asr.modelID)
        } catch {
            if Task.isCancelled { return }
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("Transcribe: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }
        var instruction = instructionRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("No instruction heard")
            return
        }
        // Apply spoken-cue substitution to the instruction only — the
        // selection is the user's pre-existing text from another app and
        // shouldn't be touched. Assistant Mode is a separate flow with no
        // mode binding, so the substitution is always on here — disabling
        // it would silently swallow user-spoken punctuation in their
        // instruction with no surface to expose it.
        instruction = SpokenCues.apply(to: instruction)

        // Deterministic memory path. "Remember that I always sign off Cheers"
        // is an instruction to the app, not a writing task — and a small local
        // model handed it will cheerfully draft an email *about* remembering
        // things. So we match the spoken prefix ourselves, store the rest, and
        // never involve the LLM.
        //
        // Only when there's no selection: with text selected the user is
        // plausibly saying "remember that, and rewrite this" — so we store the
        // fact AND still run the turn.
        let hasSelection = !(selection ?? "").isEmpty
        var rememberedNote: String? = nil
        if settings.assistantMemoryEnabled,
           let fact = AssistantMemory.rememberCommand(in: instruction) {
            let stored = AssistantMemory.shared.remember(fact)
            if !hasSelection {
                inFlightAssistant = nil
                nextAssistantIsContinuation = false
                state = .done(text: fact, pasted: false, note: stored ? "Remembered." : "Already remembered.")
                if settings.playSounds { SoundEffects.shared.playDone() }
                doneFader = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard !Task.isCancelled else { return }
                    self?.state = .idle
                }
                return
            }
            if stored { rememberedNote = fact }
        }

        // Resolve prior context for this turn. If continuing, take the verbatim
        // tail (turns after the compaction cutoff) plus the existing summary.
        // Otherwise we send nothing — a fresh thread.
        //
        // The split lives on `ChatThread` so the chat window asks the same
        // question and gets the same answer — the two entry points share a
        // store now, and they must not disagree about what the model has seen.
        var priorTurns: [ConversationTurn] = []
        var summary: String? = nil
        if continues, let active = activeThread {
            (priorTurns, summary) = active.activeAssistantContext
        }

        // The Assistant Mode entry-point already guarded against .none, so
        // currentLLM() here is non-nil under normal flow. If settings flipped
        // mid-flight (unlikely) we fail cleanly.
        guard let llm = currentLLM() else {
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("LLM is disabled. Pick one in Settings → Models.")
            return
        }

        // Pre-call compaction. Estimate input tokens; if over budget, summarise
        // the oldest turns (always keeping at least the last 2 verbatim). On
        // summariser failure we surface a hard "conversation too long" error
        // rather than silently dropping context — the user said that's the
        // right call.
        // Read the press-time document context now — after transcription, so
        // the detached AX capture has long since landed (read here rather than
        // snapshotted at key-release to dodge the struct-copy race). Resolve the
        // window-vision read-back too (also kicked off at trigger time) and fold
        // it in: its terms join the AX terms, its visible text becomes the
        // [SCREEN] block the assistant can reason over.
        let visionAttempted = inFlightAssistant?.visionTask != nil
        let documentReason = inFlightAssistant?.contextReason ?? ""
        var visionReadback = WindowVisionContext.VisionReadback.empty
        var screenImage: CGImage? = nil
        if let task = inFlightAssistant?.visionTask {
            // Same reasoning as the dictation path: this await can run to tens
            // of seconds on an MLX vision model, and the HUD was still claiming
            // to be transcribing throughout.
            state = .readingScreen(purpose: .content)
            inFlightAssistant?.visionTask = nil
            switch await task.value {
            case .briefing(let readback):
                visionReadback = readback
            case .image(let image):
                // Single stage: nothing to merge into the text context — the
                // screenshot rides along with the assistant call itself.
                screenImage = image
            }
        }
        let assistantContext = assistantContextMerging(visionReadback)
        var pendingCompactionIndex: Int? = nil
        let estimate = ConversationContextBudget.estimateInputTokens(
            priorTurns: priorTurns, summary: summary,
            selection: selection, instruction: instruction,
            context: assistantContext
        )
        if estimate > llm.assistantInputTokenBudget {
            guard priorTurns.count > 2, let active = activeThread else {
                inFlightAssistant = nil
                nextAssistantIsContinuation = false
                fail("This conversation is too long. Start a new one.")
                return
            }
            let toSummarise = Array(priorTurns.prefix(priorTurns.count - 2))
            let keep = Array(priorTurns.suffix(2))
            state = .compacting
            do {
                let newSummary = try await LLMScheduler.shared.run(.interactive) {
                    try await llm.summariseConversation(
                        turns: toSummarise,
                        priorSummary: summary,
                        cancellation: { Task.isCancelled }
                    )
                }
                if Task.isCancelled { return }
                summary = newSummary
                priorTurns = keep
                // Index of the last summarised turn within the *full* turn list.
                // count - keep.count - 1 = the last index now compacted.
                pendingCompactionIndex = active.assistantTurns.count - keep.count - 1
            } catch {
                if Task.isCancelled { return }
                inFlightAssistant = nil
                nextAssistantIsContinuation = false
                fail("This conversation is too long. Start a new one.")
                return
            }
        }

        state = .assisting
        // Memory is a store, not a setting, so it's composed here rather than
        // inside `effectiveAssistantPrompt` — Settings shouldn't have to reach
        // into a file-backed singleton to render a prompt preview.
        // `let`, not a mutated var: it's captured by the @Sendable closure
        // handed to LLMScheduler, and Swift 6 rejects a captured mutable local.
        let assistantSystemPrompt: String = {
            let base = settings.effectiveAssistantPrompt
            guard settings.assistantMemoryEnabled,
                  let memory = AssistantMemory.shared.promptBlock() else { return base }
            return base + "\n\n" + memory
        }()
        let result: AssistantResult
        do {
            result = try await LLMScheduler.shared.run(.interactive) {
                try await llm.assist(
                    selection: selection,
                    instruction: instruction,
                    systemPrompt: assistantSystemPrompt,
                    priorTurns: priorTurns,
                    summary: summary,
                    context: assistantContext,
                    screenImage: screenImage,
                    cancellation: { Task.isCancelled }
                )
            }
        } catch {
            if Task.isCancelled { return }
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("Assistant: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("Assistant returned no output.")
            return
        }

        // Snapshot what context fed this turn, for the result window — so the
        // captured text and the vision read are visible, not guessed at.
        let contextInfo: CapturedContextInfo? = {
            let docText = (assistantContext?.textBefore ?? "") + (assistantContext?.textAfter ?? "")
            let termCount = assistantContext?.documentTerms.count ?? 0
            // Attach when there's something to show, or vision was attempted (so
            // "vision ran but read nothing" still surfaces as a signal).
            guard visionAttempted || !docText.isEmpty || termCount > 0 else { return nil }
            return CapturedContextInfo(
                documentText: String(docText.prefix(600)),
                documentNote: docText.isEmpty ? documentReason : "",
                termCount: termCount,
                visionAttempted: visionAttempted,
                visionDescription: visionReadback.content,
                visionNote: screenImage != nil
                    ? "read the window directly"
                    : (visionReadback.failureReason ?? "")
            )
        }()

        // Fold the turn into the thread — two messages, which is what a turn
        // has always been. A follow-up appends to the active thread; anything
        // else starts a new `.assistant` one.
        //
        // The reply's `delivery` is still unknown here: whether it pasted or
        // fell back to the clipboard is decided in `deliverAssistant`, below,
        // which fills it in by id.
        let userMessage = ChatMessage(
            kind: .user,
            text: instruction,
            selection: selection,
            context: contextInfo)
        let replyMessage = ChatMessage(
            kind: .assistant,
            text: text,
            deliveryMode: result.mode)

        var thread: ChatThread
        if continues, let active = activeThread {
            thread = active
            if let idx = pendingCompactionIndex {
                thread.compaction = ConversationCompaction(
                    summary: summary ?? "", upThroughTurnIndex: idx)
            }
        } else {
            thread = ChatThread(origin: .assistant, modelID: settings.llmModelID)
        }
        thread.append(userMessage)
        thread.append(replyMessage)
        ChatStore.shared.upsert(thread)
        activeThreadID = thread.id

        UsageStatsStore.shared.record(
            mode: .assistant,
            wordsIn: UsageStatsStore.wordCount(instruction),
            wordsOut: UsageStatsStore.wordCount(text)
        )

        // The model's own `REMEMBER:` line, if it emitted one. Parsed off the
        // output by `LLMTextUtilities.parseAssistant`, so `text` above is
        // already clean.
        if settings.assistantMemoryEnabled, let fact = result.remember {
            if AssistantMemory.shared.remember(fact) { rememberedNote = fact }
        }

        await deliverAssistant(
            text: text,
            mode: result.mode,
            hadSelection: selection != nil,
            threadID: thread.id,
            replyID: replyMessage.id,
            remembered: rememberedNote
        )
        inFlightAssistant = nil
        nextAssistantIsContinuation = false
    }

    private func deliverAssistant(
        text: String, mode: AssistantMode, hadSelection: Bool,
        threadID: UUID, replyID: UUID, remembered: String? = nil
    ) async {
        // Trailing space so the next keystroke doesn't glue itself to this chunk —
        // same reasoning as `finish()`. Assistant Mode is mode-less, so the
        // emoji-tidy pass always runs — matches the always-on substitution on
        // the instruction side.
        var text = text
        text = SpokenCues.tidyDelivery(text)
        text = Self.withTrailingSpace(text)
        lastResult = text
        var pasted = false
        var note: String

        // Conversation mode: the result window is already open, so the user is
        // conversing with the assistant rather than editing in another app.
        // Never paste in this state, regardless of the model's REPLACE/DRAFT
        // classification — the reply just appends to the conversation, which
        // the window picks up automatically from ChatStore. Closing
        // the window ends conversation mode (and clears the active thread).
        let inConversationMode = resultWindowIsVisible?() == true
        if inConversationMode {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pasted = false
            note = "Added to conversation"
        } else {
            switch mode {
            case .replace:
                // Only synthesise ⌘V if the focused element is actually an editable
                // text input. Otherwise the paste would land somewhere unintended —
                // a URL bar, a search box on a web page the user wasn't typing
                // into, or simply nowhere at all. Fall back to DRAFT-style
                // clipboard + window so the user can read and place it themselves.
                if !TextInjector.focusedElementIsEditableText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    pasted = false
                    note = "No text input focused — copied to clipboard"
                    break
                }
                // Paste-replace the still-selected text, or insert at the cursor if
                // there was no selection. TextInjector handles both — synthetic ⌘V
                // overwrites a selection if one exists, or just inserts otherwise.
                // selectAfterPaste keeps the just-inserted text selected so the
                // user can immediately reprompt the assistant on it.
                switch injector.deliver(text: text, selectAfterPaste: true) {
                case .pasted:
                    pasted = true
                    note = hadSelection ? "Replaced selection" : "Inserted"
                case .copiedOnly(let reason):
                    pasted = false
                    note = reason
                }
            case .draft:
                // Draft mode: never paste — just leave the result on the clipboard so
                // the user pastes it wherever they actually want it.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                pasted = false
                note = "Copied — ⌘V to paste"
            }
        }

        // Record what actually happened to the reply, now that it has. The
        // model's REPLACE/DRAFT classification is an intent; this is the
        // outcome, and the two differ whenever the paste had nowhere to land.
        var delivered = ChatStore.shared.thread(id: threadID)
        if var message = delivered?.messages.first(where: { $0.id == replyID }) {
            message.delivery = note
            delivered?.update(message)
            if let delivered { ChatStore.shared.upsert(delivered) }
        }

        // Always notify the host that a turn finished. When the result is on
        // the clipboard rather than pasted, the host surfaces the window so
        // the user can read it; otherwise it only refreshes the window if
        // it's already open (e.g. a multi-turn REPLACE thread).
        if let delivered { onAssistantTurnCompleted?(delivered, !pasted) }

        // Surface anything we just learned. Memory that writes itself silently
        // is memory the user can't correct.
        if let remembered {
            note = note.isEmpty ? "Remembered: \(remembered)" : "\(note) · Remembered: \(remembered)"
        }

        state = .done(text: text, pasted: pasted, note: note)
        if settings.playSounds { SoundEffects.shared.playDone() }
        // Assistant outputs are often longer than dictation transcripts — give the
        // user time to actually read what just landed before the HUD fades.
        doneFader = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(3500))
            guard !Task.isCancelled else { return }
            self?.state = .idle
        }
    }
}
