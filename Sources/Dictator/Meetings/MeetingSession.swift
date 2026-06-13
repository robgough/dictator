import Foundation
import Observation
import AppKit

/// State machine for ONE meeting. Mirrors `Pipeline.swift` in shape but is
/// owned by the Meetings window, not the HUD — meetings and dictation are
/// independent flows with separate state.
///
/// The session holds either:
///   - a *live* recording in flight (state moves through
///     warmingUp → recording → stopping → captured → processing → ready),
///   - or a *historic* meeting loaded from disk (created in `.ready` —
///     the audio + transcript are already on disk from a previous run).
///
/// Cancelling a live recording mid-flight keeps the partial audio so it
/// can be retranscribed later (state lands in `.captured`).
@MainActor
@Observable
final class MeetingSession: Identifiable {
    enum State: Equatable {
        case idle
        case warmingUp
        case recording(elapsed: TimeInterval, micLevel: Float, sysLevel: Float)
        case stopping
        case importing(progress: Double)
        case captured
        case loadingASR(progress: Double)
        case transcribingMic(progress: Double)
        case transcribingSystem(progress: Double)
        case loadingDiarizer(progress: Double)
        case diarizing(progress: Double)
        case merging
        case summarising
        case ready
        case failed(String)

        var isProcessing: Bool {
            switch self {
            case .importing, .loadingASR, .transcribingMic, .transcribingSystem,
                 .loadingDiarizer, .diarizing, .merging, .summarising:
                return true
            default: return false
            }
        }

        var isLive: Bool {
            switch self {
            case .warmingUp, .recording, .stopping: return true
            default: return false
            }
        }
    }

    let id: UUID
    var meta: MeetingMeta
    private(set) var state: State {
        didSet {
            // Keep the coarse `isLive` / `isProcessing` mirrors in step with the
            // full state. Guarded so they mutate only on a real flip:
            // @Observable invalidates on every assignment, even a same-value one,
            // and the whole point of these mirrors is to NOT invalidate on the
            // 10×/sec `.recording` meter ticks.
            let live = state.isLive
            if live != isLive { isLive = live }
            let processing = state.isProcessing
            if processing != isProcessing { isProcessing = processing }
        }
    }

    /// Coarse, transition-only mirrors of `state.isLive` / `state.isProcessing`.
    ///
    /// The Meetings window chrome — `MeetingsRootView`'s `.toolbar`, the sidebar
    /// "return to recording" banner condition, the detail-pane routing — keys off
    /// these instead of reading `state` directly. `state` is reassigned 10×/sec
    /// during a live recording (the meter/elapsed tick in `startTimerLoop`), and
    /// because observation is property-level, any read of `state` inside
    /// `MeetingsRootView.body` re-evaluates the whole split view — including the
    /// toolbar — on every tick. Re-vending the toolbar that aggressively during
    /// the window's display-commit cycle intermittently trips an AppKit autolayout
    /// exception in `-[NSWindow _postWindowNeedsUpdateConstraints]` and crashes the
    /// app (the 2026-06-07 report). These booleans flip only at real transitions,
    /// so the chrome reconciles a handful of times per meeting. The live meters
    /// that genuinely need 10fps live in `MeetingDetailView`, which keeps reading
    /// `state` directly via its own `@Bindable session`.
    ///
    /// `didSet` doesn't fire during `init`, so any initializer that lands in a
    /// live/processing state must seed these explicitly (see `init(forImport:)`).
    private(set) var isLive = false
    private(set) var isProcessing = false
    /// Bumped whenever transcript.json / tracks.json are rewritten outside a
    /// full re-process (currently: speaker merge), so views holding cached
    /// copies know to reload.
    private(set) var transcriptRevision = 0

    private let recorder = MeetingAudioRecorder()
    private let micRecorder = MeetingMicRecorder()
    private let processor = MeetingProcessor()
    private var timerTask: Task<Void, Never>?
    private var lastMicLevel: Float = 0
    private var lastSystemLevel: Float = 0

    /// Whether each source has delivered any above-floor audio during this
    /// recording. Drives the affirmative "✓ hearing you / them" cues — once
    /// true, the user has positive proof that side is being captured. Reset at
    /// the start of each recording.
    private(set) var micHeard = false
    private(set) var systemHeard = false

    /// Draft transcript service, live for the duration of a recording. Nil
    /// outside of an active recording (and for sessions opened from disk
    /// or via import — those go straight to the post-capture processor).
    /// Exposed so `LiveRecordingView` can subscribe to its `interimText`
    /// and re-render the draft as new chunks land.
    private(set) var liveTranscriber: MeetingLiveTranscriber?

    /// Live first-pass notes builder, present for the duration of a recording
    /// when live notes are enabled and an LLM is configured. Exposed so
    /// `LiveRecordingView` can render its growing `liveNotes`.
    private(set) var notesAccumulator: MeetingNotesAccumulator?

    /// Set when the most recent notes pass failed, so the UI can surface it
    /// instead of silently leaving stale/empty notes. Cleared when a new pass
    /// starts or succeeds.
    private(set) var notesError: String?

    /// Live coach signals (talk balance, monologue timer, pace…), present for
    /// the duration of a recording when the coach is enabled. Fed from the
    /// same level callbacks that drive the meters — no capture of its own.
    /// Exposed so `LiveRecordingView` renders the metrics strip off it.
    private(set) var coachEngine: MeetingCoachEngine?
    /// Checklist state captured at stop, consumed by `finaliseCoachMetrics`.
    private var pendingCoachOutcome: MeetingCoachLiveState?
    /// True while the coach-report LLM pass runs — drives the Coach tab's
    /// spinner/disabled re-run button.
    private(set) var coachReportRunning = false
    private var coachLiveWriteTask: Task<Void, Never>?
    /// Pad lines already lifted to the checklist this session (hash-once,
    /// so later pad edits don't re-lift).
    private var liftedPadLines: Set<String> = []

    /// Source-app detection + calendar matching, live for the recording.
    private let sourceAppDetector = MeetingSourceAppDetector()
    private var calendarMatchTask: Task<Void, Never>?

    /// Opt-in window-scoped screen capture, live for the recording. The start
    /// runs in its own task so SCStream setup doesn't delay the audio path.
    /// Non-private so the live-recording UI can show the current target +
    /// latest frame and drive the change-target menu.
    let screenCapturer = MeetingScreenCapturer()
    private var screenCaptureTask: Task<Void, Never>?

    /// Per-speaker voice embeddings from the post-pass diarization, set by
    /// `MeetingProcessor.run` — input to the people-store link pass.
    @ObservationIgnored var speakerEmbeddings: [String: [Float]]?

    /// The user's own notes for this meeting — the pad they type into during
    /// (or after) recording. Loaded from `pad.md` on init, autosaved through
    /// `updatePad` with a short debounce, and fed to the final notes pass as
    /// authoritative input. Empty string = no pad.
    private(set) var padText: String = ""
    private var padSaveTask: Task<Void, Never>?

    /// Streams the live notes + transcript to disk every few seconds while
    /// recording (for external readers + crash safety). Present only during a
    /// live recording, alongside `liveTranscriber`. See `MeetingLiveMirror`.
    private var liveMirror: MeetingLiveMirror?

    /// Active capture warnings — currently one per source ("mic" /
    /// "system"), keyed so a re-warn from the same source overwrites
    /// instead of stacking duplicates. Surfaced by `LiveRecordingView`
    /// as a dismissible warning banner so the user can see (e.g.) that
    /// FaceTime is blocking system capture or that the mic recorder
    /// isn't getting buffers, instead of staring at flat meters.
    private(set) var captureWarnings: [CaptureWarning] = []

    struct CaptureWarning: Identifiable, Equatable {
        enum Source: String { case mic, system }
        let source: Source
        let message: String
        var id: String { source.rawValue }
    }

    var micFileURL: URL? {
        guard meta.audioFiles.mic != nil else { return nil }
        return MeetingStorage.micURL(for: id)
    }
    var systemFileURL: URL? {
        guard meta.audioFiles.system != nil else { return nil }
        return MeetingStorage.systemURL(for: id)
    }

    /// Construct a fresh live session — folder is created, meta is staged
    /// in memory only (persisted once recording stops).
    init(forLiveRecording id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        let title = Self.defaultTitle(for: createdAt)
        self.meta = MeetingMeta(
            id: id,
            title: title,
            createdAt: createdAt,
            durationSeconds: 0,
            source: .live,
            audioFiles: .init(mic: MeetingStorage.micFilename, system: MeetingStorage.systemFilename),
            speakers: MeetingMeta.defaultLiveSpeakers
        )
        self.state = .idle
        self.padText = MeetingStorage.readPad(for: id)
    }

    /// Construct a session for an in-progress file import. Lands in
    /// `.importing(0)`; the caller drives `runImport` to do the
    /// background re-encode (which advances progress) and then chains
    /// into the post-capture processor.
    init(forImport meta: MeetingMeta) {
        self.id = meta.id
        self.meta = meta
        self.state = .importing(progress: 0)
        // didSet doesn't run during init, so seed the mirror to match `.importing`.
        self.isProcessing = true
        self.padText = MeetingStorage.readPad(for: meta.id)
    }

    /// Construct from on-disk meta. Lands in `.ready` if a transcript is
    /// already on disk; otherwise in `.captured` so the "Process now"
    /// button surfaces — covers the crash-mid-process case where audio
    /// + meta were written but the transcript stage never finished.
    init(from meta: MeetingMeta) {
        self.id = meta.id
        self.meta = meta
        self.padText = MeetingStorage.readPad(for: meta.id)
        let hasTranscript = FileManager.default.fileExists(
            atPath: MeetingStorage.transcriptURL(for: meta.id).path
        )
        let fm = FileManager.default
        let micPresent = meta.audioFiles.mic != nil
            && fm.fileExists(atPath: MeetingStorage.micURL(for: meta.id).path)
        let sysPresent = meta.audioFiles.system != nil
            && fm.fileExists(atPath: MeetingStorage.systemURL(for: meta.id).path)
        let hasAnyAudio = micPresent || sysPresent
        if hasTranscript {
            self.state = .ready
        } else if hasAnyAudio {
            self.state = .captured
        } else {
            // No transcript and no audio — show as ready and let the
            // detail view's empty-transcript placeholder handle it.
            self.state = .ready
        }
    }

    // MARK: - Live recording

    /// Begin capture. The session takes care of probing system-audio-
    /// recording permission first; on denial it lands in `.failed`. The
    /// probe attempts a tap creation and treats the macOS prompt outcome
    /// as the source of truth — there's no preflight API for this bucket.
    func startRecording(
        preferredMicDevice: AudioDevice?,
        coachPlan: CoachSessionPlan? = nil,
        coachDisabled: Bool = false
    ) async {
        guard case .idle = state else { return }
        state = .warmingUp
        captureWarnings = []
        micHeard = false
        systemHeard = false

        // The preset sheet's chosen type drives the notes template too —
        // one choice, both behaviours. Persisted with the rest of meta at
        // stop.
        if let typeID = coachPlan?.typeID {
            meta.meetingType = MeetingTypeID(typeID)
        }

        switch await AudioRecordingPermission.probe() {
        case .granted:
            break
        case .notGranted:
            state = .failed("Dictator needs System Audio Recording permission to capture meeting audio. Open System Settings to grant it, then try again.")
            return
        }

        recorder.onReady = { [weak self] in
            guard let self else { return }
            self.state = .recording(elapsed: 0, micLevel: 0, sysLevel: 0)
            AppState.shared.meetingRecordingStartedAt = Date()
            self.startTimerLoop()
            // Coach clock starts when capture actually starts, so its t=0
            // lines up with audio time. Mirrored onto AppState so the notch
            // island can render the strip with the Meetings window closed.
            self.coachEngine?.start()
            AppState.shared.activeCoachEngine = self.coachEngine
            // Context: who's hosting the call (audio-process sampling) and
            // which calendar event this is. Both off the critical path —
            // results land on meta at stop / when the match returns.
            self.sourceAppDetector.start()
            if AppState.shared.settings.meetingCalendarMatchingEnabled {
                self.calendarMatchTask = Task { @MainActor [weak self] in
                    guard let context = await MeetingCalendarMatcher.match(recordingStart: Date()) else { return }
                    guard let self, self.state.isLive else { return }
                    self.meta.calendar = context
                    // The scheduled end unlocks the coach's "wrapping up"
                    // nudge — express it on the engine's elapsed clock.
                    if let engine = self.coachEngine {
                        engine.scheduledEndElapsedSeconds =
                            engine.elapsedSeconds + context.endDate.timeIntervalSinceNow
                    }
                }
            }
        }
        // Stash the latest level; the timer loop publishes it into `state` at a
        // fixed meter cadence. We deliberately do NOT push `state` per buffer:
        // the CATap IOProc fires this ~100×/s for the whole meeting, and each
        // push re-rendered the live view subtree (which carries the growing
        // transcript) — a steady main-actor tax that compounded over a long
        // call. `lastSystemLevel` is private, so writing it observes nothing.
        recorder.onLevel = { [weak self] _, sys in
            guard let self else { return }
            self.lastSystemLevel = sys
            if sys > 0.02 { self.systemHeard = true }
            self.coachEngine?.ingestSystemLevel(sys)
        }
        recorder.onUnexpectedStop = { [weak self] reason in
            guard let self else { return }
            self.timerTask?.cancel()
            self.timerTask = nil
            // Interrupted recording — finalise the live mirror (status
            // `interrupted`, files kept for recovery/inspection) while the
            // producers are still alive, then tear them down.
            self.liveMirror?.finish(status: .interrupted)
            self.liveMirror = nil
            self.liveTranscriber?.stop()
            self.liveTranscriber = nil
            _ = self.notesAccumulator?.stop()
            self.notesAccumulator = nil
            self.coachEngine?.stop()
            self.coachEngine = nil
            AppState.shared.activeCoachEngine = nil
            AppState.shared.meetingRecordingStartedAt = nil
            self.calendarMatchTask?.cancel()
            self.calendarMatchTask = nil
            if self.meta.sourceApp == nil {
                self.meta.sourceApp = self.sourceAppDetector.stop()
            }
            // Release the screen-capture stream (frames already on disk stand).
            self.screenCaptureTask?.cancel()
            self.screenCaptureTask = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                let shots = await self.screenCapturer.stop()
                if !shots.screenshots.isEmpty {
                    self.meta.screenshotCount = shots.screenshots.count
                    try? MeetingStorage.writeMeta(self.meta)
                    MeetingsStore.shared.upsert(self.meta)
                }
            }
            self.state = .failed(reason)
        }
        recorder.onCaptureWarning = { [weak self] message in
            self?.upsertCaptureWarning(source: .system, message: message)
        }
        micRecorder.onLevel = { [weak self] mic in
            guard let self else { return }
            self.lastMicLevel = mic
            if mic > 0.02 { self.micHeard = true }
            self.coachEngine?.ingestMicLevel(mic)
        }
        micRecorder.onCaptureWarning = { [weak self] message in
            self?.upsertCaptureWarning(source: .mic, message: message)
        }

        // Live transcript scaffolding. Opt-out via the "live transcript"
        // setting: when it's off we never build the transcriber and never wire
        // the recorders' sample sinks, so the whole live ASR path (per-buffer
        // resample + chunk + draft render) is skipped — the cheapest way to
        // lighten a long recording. Constructed once we know recording is going
        // to be attempted (post permission probe), wired to both recorders, and
        // torn down on stop / unexpected stop. The transcriber is given the
        // parakeet model id once at construction; settings changes mid-meeting
        // don't apply until the next recording.
        if AppState.shared.settings.meetingLiveTranscriptEnabled {
            let liveModelID = AppState.shared.settings.parakeetModelID
            let live = MeetingLiveTranscriber(parakeetModelID: liveModelID)
            liveTranscriber = live
            recorder.onSystemSamples = { [weak live] mono, sampleRate in
                live?.feedSystemSamples(mono, sampleRate: sampleRate)
            }
            micRecorder.onBuffer = { [weak live] mono, sampleRate in
                live?.feedMicSamples(mono, sampleRate: sampleRate)
            }
        }

        // Live coach signals. Works with or without the live transcriber —
        // levels alone give talk balance / monologues / interruptions; the
        // transcriber adds pace / fillers / questions and the checklist
        // watcher when it's on. Constructed before the accumulator so the
        // watcher can ride its loop.
        if AppState.shared.settings.meetingCoachEnabled, !coachDisabled {
            let engine = MeetingCoachEngine(transcriber: liveTranscriber, plan: coachPlan)
            coachEngine = engine
            // Crash-mirror the checklist (debounced) so mid-meeting ad-hoc
            // adds survive — same ethos as the live mirror, separate private
            // file (never the markdown mirrors).
            engine.onChecklistChanged = { [weak self] in self?.scheduleCoachLiveWrite() }
            if engine.hasChecklist { scheduleCoachLiveWrite() }
        }

        if let live = liveTranscriber {
            // Live first-pass notes and/or the checklist watcher — one
            // accumulator, one serialised live-LLM loop. Notes need the
            // setting on; the watcher needs a checklist; both need an LLM.
            var accumulator: MeetingNotesAccumulator?
            let notesEnabled = AppState.shared.settings.meetingLiveNotesEnabled
            // The coach's checklist starts empty and fills mid-meeting, so
            // the watcher's loop must exist whenever the coach does — it
            // no-ops until items arrive.
            if AppState.shared.settings.activeLLMEngine() != nil,
               notesEnabled || coachEngine != nil {
                let acc = MeetingNotesAccumulator(
                    transcriber: live,
                    settings: AppState.shared.settings,
                    coach: coachEngine,
                    notesEnabled: notesEnabled
                )
                notesAccumulator = acc
                acc.start()
                accumulator = acc
            }

            // Mirror the live notes + transcript to disk as they grow, so an
            // external tool can read the meeting in near-real-time and a crash
            // mid-recording doesn't lose the work. Driven by the producers'
            // update callbacks (debounced inside the mirror); torn down on stop.
            let mirror = MeetingLiveMirror(
                meetingID: id,
                title: meta.title,
                startedAt: meta.createdAt,
                transcriber: live,
                accumulator: accumulator
            )
            liveMirror = mirror
            live.onTranscriptUpdated = { [weak mirror] in mirror?.scheduleWrite() }
            accumulator?.onNotesUpdated = { [weak mirror] in mirror?.scheduleWrite() }
            // Write the (empty) files immediately so they exist from t=0 and
            // visibly fill in, instead of appearing ~30 s later on the first
            // committed line / notes pass.
            mirror.start()
        }

        do {
            let folder = MeetingStorage.audioFolder(for: id)
            try await recorder.start(folder: folder, preferredMicUID: nil)
            // Mic capture runs on its own AVCaptureSession alongside the
            // CATap system recorder. Failure to start mic isn't fatal:
            // system-only recording is still useful (and surfaces in the UI
            // via didCaptureMic). Mic trouble is reported via onCaptureWarning
            // rather than thrown, so there's nothing to catch here.
            await micRecorder.start(
                at: MeetingStorage.micURL(for: id),
                preferredDevice: preferredMicDevice
            )
            // Configure screen capture unconditionally — the live "Shared
            // screen" panel can toggle it on/off per meeting even when the
            // default is off. Auto-start only when the setting wants it. Done
            // after audio is up so SCStream setup never delays record-live.
            screenCapturer.configure(
                folder: MeetingStorage.screenshotsFolder(for: id),
                preferredBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
            if AppState.shared.settings.meetingCaptureScreenshots {
                startScreenCapture()
            }
        } catch {
            state = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    /// Auto-start window-scoped capture if Screen Recording is granted. When it
    /// isn't, trigger the one-time system prompt so the *next* meeting can
    /// capture (the grant only takes effect after the prompt/relaunch), and
    /// leave this meeting audio-only — the user can still flip capture on from
    /// the live panel once granted. Runs in `screenCaptureTask` so the stream
    /// bring-up doesn't block record start.
    private func startScreenCapture() {
        guard ScreenRecordingPermission.hasAccess() else {
            ScreenRecordingPermission.request()
            NSLog("[Dictator] Screenshots: Screen Recording not granted — prompted; capture skipped this meeting")
            return
        }
        screenCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.screenCapturer.enable() {
            case .started:
                break
            case .noWindow:
                NSLog("[Dictator] Screenshots: no meeting window on screen — capture skipped (window-scoped only, never whole display)")
            case .failed(let message):
                NSLog("[Dictator] Screenshots: capture failed to start: \(message)")
            }
        }
    }

    /// Insert (or overwrite by source) a capture warning. Keeping warnings
    /// keyed by source means a re-fire from the same recorder doesn't
    /// stack duplicates, but mic + system warnings happily coexist.
    private func upsertCaptureWarning(source: CaptureWarning.Source, message: String) {
        if let idx = captureWarnings.firstIndex(where: { $0.source == source }) {
            captureWarnings[idx] = CaptureWarning(source: source, message: message)
        } else {
            captureWarnings.append(CaptureWarning(source: source, message: message))
        }
    }

    /// Dismiss a banner from the live UI. The recorder itself is
    /// unaffected — this just hides the message until the next recording.
    func dismissCaptureWarning(source: CaptureWarning.Source) {
        captureWarnings.removeAll { $0.source == source }
    }

    /// Stop recording. Writes the meta.json with the final duration,
    /// transitions through `.stopping` → `.captured`, then kicks off the
    /// processor automatically.
    func stopRecording(parakeetModelID: String) async {
        guard state.isLive else { return }
        state = .stopping
        AppState.shared.meetingRecordingStartedAt = nil
        timerTask?.cancel()
        timerTask = nil
        calendarMatchTask?.cancel()
        calendarMatchTask = nil
        if meta.sourceApp == nil {
            meta.sourceApp = sourceAppDetector.stop()
        }
        // Tear down both recorders in parallel so we don't double the wait.
        async let systemStop: MeetingAudioRecorder.StopResult = recorder.stop()
        async let micStop: Void = micRecorder.stop()
        let systemResult = await systemStop
        await micStop
        // Stop screen capture: let the start task settle first (it may still be
        // bringing the stream up), then flush. Off the critical UI path — the
        // count lands on meta below.
        await screenCaptureTask?.value
        screenCaptureTask = nil
        let screenshots = await screenCapturer.stop()
        meta.screenshotCount = screenshots.screenshots.isEmpty ? nil : screenshots.screenshots.count
        // Tear down the live transcriber after the recorders so any final
        // buffers they enqueued get a chance to land before we cancel the
        // in-flight chunk task. The Parakeet weights themselves live in
        // `ParakeetServiceHolder.shared` and stay warm — the processor
        // about to run will reuse them immediately.
        // Finalise the live transcript + live notes before tearing them down:
        // settle the held-back tail (the last couple of phrases) into the
        // transcript, then run one last notes pass so the live notes are
        // complete. Persisted below (isFinal=false) so they survive even if the
        // post-capture notes pass doesn't run (auto-notes off) or fails; the
        // full pass overwrites them with isFinal=true when it succeeds.
        await liveTranscriber?.finishPending()
        let liveNotesMarkdown = ((await notesAccumulator?.finish()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Finalise the live mirror while the producers are still alive, so the
        // last snapshot has the complete transcript + notes. Files are kept with
        // status `stopped`; the canonical output lands in meta.json / the
        // post-pass transcript.json.
        liveMirror?.finish(status: .stopped)
        liveMirror = nil
        liveTranscriber?.stop()
        liveTranscriber = nil
        notesAccumulator = nil
        // Capture the checklist's final state before the engine goes — the
        // post-pass folds it into meta.coach next to the recomputed metrics.
        coachLiveWriteTask?.cancel()
        coachLiveWriteTask = nil
        if let engine = coachEngine, engine.hasChecklist {
            pendingCoachOutcome = MeetingCoachLiveState(
                presetTypeID: engine.presetTypeID,
                profileIDs: engine.profileIDs,
                outcomes: engine.outcomes()
            )
        }
        coachEngine?.stop()
        coachEngine = nil
        AppState.shared.activeCoachEngine = nil
        // Reflect what actually landed on disk. The CATap process tap owns
        // the system track; the parallel AVAudioEngine owns the mic.
        meta.audioFiles = MeetingMeta.AudioFiles(
            mic: micRecorder.didCapture ? MeetingStorage.micFilename : nil,
            system: systemResult.didCaptureSystem ? MeetingStorage.systemFilename : nil
        )
        meta.durationSeconds = systemResult.durationSeconds
        if !liveNotesMarkdown.isEmpty {
            let live = MeetingNotes(
                markdown: liveNotesMarkdown,
                modelID: MeetingSummaryService.engineModelID(settings: AppState.shared.settings),
                generatedAt: Date(),
                isFinal: false
            )
            // `notes` shows immediately; `rawNotes` is the kept copy that
            // survives the full rewrite so it stays available to compare.
            meta.notes = live
            meta.rawNotes = live
        }
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
        // Settle any pad text still inside the autosave debounce window —
        // the final notes pass that's about to run reads pad.md from disk.
        flushPad()
        state = .captured
        await runProcessor(parakeetModelID: parakeetModelID)
    }

    // MARK: - Import / re-process

    /// Drive a freshly-shell'd import session: do the off-main audio
    /// re-encode (advancing `.importing(progress:)` as it goes) and then
    /// chain into the existing post-capture processor. The shell session
    /// (constructed via `MeetingSession(forImport:)`) lands in
    /// `.importing(0)` so the user sees activity immediately rather than
    /// staring at a beach ball while the source file gets re-encoded.
    func runImport(from source: URL, parakeetModelID: String) async {
        guard case .importing = state else { return }
        do {
            try await MeetingImporter.reencodeAudio(
                from: source,
                to: MeetingStorage.systemURL(for: id)
            ) { [weak self] fraction in
                guard let self else { return }
                self.state = .importing(progress: fraction)
            }
            state = .captured
            await runProcessor(parakeetModelID: parakeetModelID)
        } catch {
            state = .failed("Couldn't import audio: \(error.localizedDescription)")
        }
    }

    /// Run (or re-run) the post-capture pipeline. Used after a fresh
    /// recording and from the "Process now" button on a meeting that
    /// crashed mid-process.
    func runProcessor(parakeetModelID: String) async {
        // Whatever happens below, hand the meeting-only models back when the
        // post-pass finishes so two back-to-back long calls don't keep several
        // model sets resident and tip the machine into swap (the felt "after
        // two meetings everything's slow"). Runs on success and failure.
        // The compactor mark keeps the launch sweep's hands off this
        // meeting's audio while the processor is reading it.
        MeetingAudioCompactor.shared.markProcessing(id: id)
        defer {
            reclaimAfterProcessing()
            MeetingAudioCompactor.shared.unmarkProcessing(id: id)
        }
        do {
            state = .loadingASR(progress: 0)
            // Pull the dedup toggle off settings just before we run, so the
            // user's last save wins — the processor instance is held for the
            // lifetime of the session, but the setting is the source of truth.
            processor.dedupeMicEchoes = AppState.shared.settings.meetingDedupeMicEchoes
            try await processor.run(session: self, parakeetModelID: parakeetModelID) { [weak self] stage, fraction in
                guard let self else { return }
                switch stage {
                case .loadingASR: self.state = .loadingASR(progress: fraction)
                case .transcribingMic: self.state = .transcribingMic(progress: fraction)
                case .transcribingSystem: self.state = .transcribingSystem(progress: fraction)
                case .loadingDiarizer: self.state = .loadingDiarizer(progress: fraction)
                case .diarizing: self.state = .diarizing(progress: fraction)
                case .writingTranscript: self.state = .merging
                }
            }
            MeetingsStore.shared.upsert(meta)

            // Coach metrics — deterministic, recomputed from the finished
            // transcript's word timings (authoritative where the live signals
            // were provisional). Cheap pure code, so it runs for every
            // meeting regardless of preset; the LLM coach report (later
            // phase) is the part that stays user-triggered. Private: lands
            // on meta.coach, which the markdown mirrors never read.
            finaliseCoachMetrics()

            // Processing always finishes at the transcript. Final notes are
            // never written automatically any more — the user reviews the
            // transcript and fixes speaker names first, then triggers the
            // notes pass with the Generate button whenever they like (see
            // `generateNotes`). So we land in `.ready` here unconditionally.
            let settings = AppState.shared.settings
            let llmAvailable = settings.activeLLMEngine() != nil
            state = .ready

            // Guess real speaker names from the conversation, so the roster the
            // user reviews reads "Rory" / "Pat" instead of "Speaker 1" before
            // they ever open it. Conservative and non-destructive — only touches
            // default/previously-guessed labels, never a manual rename.
            if llmAvailable {
                await inferSpeakerNames(settings: settings)
            }

            // People recognition: match this meeting's speaker voices against
            // the cross-meeting store (after naming, so a new face gets
            // learned under its best-known name).
            linkPeopleAcrossMeetings()

            // Auto title suggestion. Always runs when an LLM is
            // available — the call is short and cheap, and a meeting
            // titled "Q3 launch planning" is dramatically more useful
            // than "Meeting on 2026-05-27 14:32" when you're scanning
            // the sidebar a week later. Quality-gated and only applied
            // when the current title still looks like the default —
            // we never overwrite a manual rename.
            if llmAvailable {
                await maybeAutoRename(settings: settings)
            }

            // Tell the user the meeting is transcribed and ready to review if
            // they recorded and walked away — they can come back, check who
            // said what, and generate notes when convenient. Only for live
            // recordings, and only when we're backgrounded (if they're looking
            // at the window they can already see it).
            if meta.source == .live, !NSApp.isActive {
                MeetingNotifier.notifyTranscriptReady(meetingTitle: meta.title)
            }

            // The transcript is on disk, so the crash-safe-PCM rationale for
            // the audio has expired — re-encode the tracks to AAC in place
            // (~10× smaller). Last on purpose: it shares no models with the
            // LLM passes above and nothing waits on it.
            await MeetingAudioCompactor.shared.compact(meetingID: id)
        } catch {
            state = .failed("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Compute the deterministic conversation metrics from the finished
    /// transcript and persist them on `meta.coach`. Silent no-op when there's
    /// no transcript or nobody is marked `isMe` (imports — there's no "me"
    /// side to coach).
    private func finaliseCoachMetrics() {
        guard let transcript = MeetingStorage.readTranscript(for: id) else { return }
        let myIDs = Set(meta.speakers.filter(\.isMe).map(\.id))
        guard !myIDs.isEmpty else { return }
        let metrics = CoachMetricsBuilder.build(
            transcript: transcript,
            mySpeakerIDs: myIDs,
            durationSeconds: meta.durationSeconds
        )
        // Checklist outcomes: from the just-stopped session, or — after a
        // crash / "Process now" — from the crash-mirror file.
        let live = pendingCoachOutcome ?? MeetingStorage.readCoachLive(for: id)
        meta.coach = MeetingCoachResult(
            metrics: metrics,
            generatedAt: Date(),
            checklist: (live?.outcomes.isEmpty == false) ? live?.outcomes : nil,
            presetTypeID: live?.presetTypeID ?? (meta.meetingType == .auto ? nil : meta.meetingType.rawValue),
            profileIDs: (live?.profileIDs.isEmpty == false) ? live?.profileIDs : nil
        )
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
        MeetingStorage.deleteCoachLive(for: id)
        pendingCoachOutcome = nil
    }

    /// Debounced crash-mirror of the live checklist state (see
    /// `MeetingStorage.coachLiveURL`). Cancelled + replaced per change; the
    /// final state is captured synchronously at stop.
    private func scheduleCoachLiveWrite() {
        coachLiveWriteTask?.cancel()
        coachLiveWriteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let engine = self.coachEngine else { return }
            MeetingStorage.writeCoachLive(
                MeetingCoachLiveState(
                    presetTypeID: engine.presetTypeID,
                    profileIDs: engine.profileIDs,
                    outcomes: engine.outcomes()
                ),
                for: self.id
            )
        }
    }

    /// Release the meeting-only models once a post-pass is done. The
    /// meeting-dedicated Parakeet manager and the diarizer are used *only*
    /// during processing, so unloading them costs just a few seconds' reload
    /// next meeting while reclaiming hundreds of MB that would otherwise stay
    /// resident across calls. We deliberately do NOT unload the LLM container —
    /// it's shared with dictation's format/grammar passes and the next thing
    /// the user does might be a dictation — but we do hand its GPU buffer pool
    /// back, which is the part that actually grows.
    private func reclaimAfterProcessing() {
        MeetingParakeetServiceHolder.shared.unload()
        DiarizerServiceHolder.shared.unload(modelID: ModelCatalog.defaultDiarization.id)
        MLXLLMServiceHolder.shared.releaseGPUCache()
    }

    /// Match this meeting's speakers against the people store by voice:
    /// a known voice links (and brings its name to default/guessed labels);
    /// a named stranger becomes a new person; calendar attendees donate
    /// emails to name-matched people. Voice-only and conservative — a wrong
    /// link writes the wrong name, so unmatched anonymous speakers stay
    /// anonymous rather than spawning "Speaker 2" person records.
    private func linkPeopleAcrossMeetings() {
        guard AppState.shared.settings.peopleRecognitionEnabled else { return }
        guard let embeddings = speakerEmbeddings, !embeddings.isEmpty else { return }
        let store = PeopleStore.shared
        let modelID = ModelCatalog.defaultDiarization.id
        var changed = false

        func isDefaultLabel(_ name: String) -> Bool {
            name == "Other" || name == "Me" || name.hasPrefix("Speaker ")
        }

        // A person may be claimed by at most ONE speaker in a meeting. Two
        // chips resolving to the same person is either an over-split we won't
        // auto-merge (manual rename + speaker-merge is the right fix) or two
        // similar-sounding humans — and in that second case letting the loser
        // also "match" would fold a stranger's voice into the winner's record
        // and poison recognition for good. Assignment below is exclusive.
        var claimedPeople = Set<String>()

        // Phase 0 — re-processed meetings: existing links claim their person
        // first (and refresh the voice) so a fresh match can't steal them.
        for idx in meta.speakers.indices {
            let speaker = meta.speakers[idx]
            guard !speaker.isMe, let personID = speaker.personID else { continue }
            claimedPeople.insert(personID)
            if let embedding = embeddings[speaker.id] {
                store.recordObservation(personID: personID, embedding: embedding, modelID: modelID)
            }
        }

        // Phase 1 — voice matching, globally greedy and exclusive. Collect
        // every (speaker, person, similarity) candidate above threshold, then
        // assign best-first: the closest voice wins a contested person, and a
        // speaker whose best is taken falls through to its next-best here or
        // the name bridge below — never to a duplicate.
        struct VoiceCandidate { let speakerIdx: Int; let personID: String; let similarity: Float }
        var candidates: [VoiceCandidate] = []
        for idx in meta.speakers.indices {
            let speaker = meta.speakers[idx]
            guard !speaker.isMe, speaker.personID == nil, let embedding = embeddings[speaker.id] else { continue }
            for m in store.matches(for: embedding, modelID: modelID) {
                candidates.append(VoiceCandidate(speakerIdx: idx, personID: m.person.id, similarity: m.similarity))
            }
        }
        candidates.sort { $0.similarity > $1.similarity }
        var assignedSpeakers = Set<Int>()
        for c in candidates {
            guard !assignedSpeakers.contains(c.speakerIdx), !claimedPeople.contains(c.personID),
                  let person = store.person(id: c.personID),
                  let embedding = embeddings[meta.speakers[c.speakerIdx].id] else { continue }
            let speaker = meta.speakers[c.speakerIdx]
            meta.speakers[c.speakerIdx].personID = person.id
            store.recordObservation(personID: person.id, embedding: embedding, modelID: modelID)
            if isDefaultLabel(speaker.displayName) || speaker.nameInferred {
                // The store's name wins over a default/guessed label. Marked
                // inferred so a user rename stays authoritative (and
                // propagates back via renameSpeaker).
                meta.speakers[c.speakerIdx].displayName = person.name
                meta.speakers[c.speakerIdx].nameInferred = true
            } else if isDefaultLabel(person.name) {
                // The speaker label is better than what the store holds.
                store.rename(id: person.id, to: speaker.displayName)
            }
            assignedSpeakers.insert(c.speakerIdx)
            claimedPeople.insert(person.id)
            changed = true
            NSLog("[Dictator] People: \(speaker.id) matched '\(person.name)' (sim=\(String(format: "%.2f", c.similarity)))")
        }

        // Phase 2 — name bridge + named strangers, for speakers voice didn't
        // place. Still exclusive: a name can't bridge to an already-claimed
        // person (some other speaker voice-matched them this meeting; linking
        // the name too would double-assign one human onto two chips).
        for idx in meta.speakers.indices {
            let speaker = meta.speakers[idx]
            guard !speaker.isMe, speaker.personID == nil, let embedding = embeddings[speaker.id],
                  !isDefaultLabel(speaker.displayName) else { continue }
            let sameName = store.peopleMatching(name: speaker.displayName)
            if sameName.count == 1, !claimedPeople.contains(sameName[0].id) {
                // Known person, unrecognised voice — same human calling from a
                // different room/mic. The name bridges the gap, and storing
                // THIS environment's embedding means next time voice matches.
                meta.speakers[idx].personID = sameName[0].id
                store.recordObservation(personID: sameName[0].id, embedding: embedding, modelID: modelID)
                claimedPeople.insert(sameName[0].id)
                NSLog("[Dictator] People: \(speaker.id) linked to '\(sameName[0].name)' by name (voice below threshold — new environment learned)")
                changed = true
            } else if sameName.isEmpty {
                // A named voice we haven't met — learn them.
                let person = store.createPerson(name: speaker.displayName, embedding: embedding, modelID: modelID)
                meta.speakers[idx].personID = person.id
                claimedPeople.insert(person.id)
                changed = true
            } else {
                // Ambiguous name (2+ share it), or the lone same-named person
                // is already claimed by a closer voice this meeting — either
                // way, guessing risks the wrong name. Leave unlinked; a rename
                // to a distinct name ("Jack R") links via renameSpeaker.
                NSLog("[Dictator] People: \(speaker.id) name '\(speaker.displayName)' not bridged (ambiguous or already claimed) — left unlinked")
            }
        }

        // Calendar attendees donate emails to name-matched linked people.
        if let attendees = meta.calendar?.attendees {
            for speaker in meta.speakers {
                guard let personID = speaker.personID,
                      let person = store.person(id: personID),
                      person.emails.isEmpty else { continue }
                let firstName = person.name.split(separator: " ").first.map(String.init)?.lowercased()
                guard let firstName, firstName.count >= 3 else { continue }
                if let attendee = attendees.first(where: { ($0.name ?? "").lowercased().contains(firstName) }),
                   let email = attendee.email {
                    store.attachEmail(id: personID, email: email)
                }
            }
        }

        if changed {
            try? MeetingStorage.writeMeta(meta)
            MeetingsStore.shared.upsert(meta)
        }
    }

    /// Run the title-suggestion LLM call and, if the suggestion passes
    /// the quality gate AND the current title is still the default
    /// date-format title, apply it. Failures are silent — the meeting
    /// just keeps its default title.
    private func maybeAutoRename(settings: DictatorSettings) async {
        guard MeetingSummaryService.isDefaultMeetingTitle(meta.title) else { return }
        // Deterministic first: a matched calendar event's title IS the
        // meeting's name — no LLM guess needed (or wanted).
        if let calendarTitle = meta.calendar?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !calendarTitle.isEmpty {
            rename(to: calendarTitle)
            return
        }
        guard let transcript = MeetingStorage.readTranscript(for: id) else { return }
        do {
            if let suggestion = try await MeetingSummaryService.suggestTitle(
                transcript: transcript, meta: meta, settings: settings
            ) {
                rename(to: suggestion)
            }
        } catch {
            NSLog("[Dictator] Title suggestion failed for \(id): \(error)")
        }
    }

    /// Guess real speaker names from the transcript and apply any confident
    /// matches to `meta.speakers`. Silent and non-destructive: failures are
    /// swallowed (the speakers just keep their "Speaker N" labels) and only
    /// default/previously-guessed labels are ever touched, so a manual rename
    /// survives. Persists only when something actually changed.
    private func inferSpeakerNames(settings: DictatorSettings) async {
        guard let transcript = MeetingStorage.readTranscript(for: id) else { return }
        let updated = await MeetingSpeakerNamer.inferNames(
            transcript: transcript,
            speakers: meta.speakers,
            settings: settings
        )
        guard updated != meta.speakers else { return }
        meta.speakers = updated
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
    }

    /// Run the LLM notes pass on the current transcript and persist the
    /// finished markdown notes on meta. Non-destructive: a failure surfaces
    /// in NSLog and leaves the transcript (and any prior notes) intact (state
    /// returns to .ready). Used both by the auto-run after processing and the
    /// manual "Generate" / "Re-run" button.
    func generateNotes(settings: DictatorSettings) async {
        guard let transcript = MeetingStorage.readTranscript(for: id) else {
            NSLog("[Dictator] Skipping notes: no transcript on disk for \(id)")
            // runProcessor may have parked us in .summarising in anticipation
            // of this pass — don't strand the meeting there.
            if case .summarising = state { state = .ready }
            return
        }
        notesError = nil
        state = .summarising
        do {
            let notes = try await MeetingSummaryService.generateNotes(
                transcript: transcript,
                meta: meta,
                settings: settings
            )
            meta.notes = notes
            try? MeetingStorage.writeMeta(meta)
            MeetingsStore.shared.upsert(meta)
            state = .ready
            // The coach report rides the same user action — one Generate
            // produces notes AND the private report (it also wants the
            // fresh notes as context, and the detected type's rubric).
            // Best-effort: a report failure never disturbs the notes.
            await generateCoachReport(settings: settings)
        } catch {
            NSLog("[Dictator] Meeting notes failed for \(id): \(error)")
            notesError = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't write the notes. Tap Generate to try again."
            state = .ready
        }
    }

    /// Generate (or regenerate) the private coach report. Rides every notes
    /// generation and is re-runnable on its own from the Coach tab. No-op
    /// when the meeting has no coach data (coach off, or an import).
    func generateCoachReport(settings: DictatorSettings) async {
        guard meta.coach != nil, !coachReportRunning else { return }
        coachReportRunning = true
        defer { coachReportRunning = false }
        do {
            meta.coach = try await MeetingCoachReportService.generateReport(
                meta: meta,
                settings: settings
            )
            try? MeetingStorage.writeMeta(meta)
            MeetingsStore.shared.upsert(meta)
        } catch {
            NSLog("[Dictator] Coach report failed for \(id): \(error)")
        }
    }

    // MARK: - Pad (the user's own notes)

    /// Update the pad text, autosaving to `pad.md` after a short debounce so
    /// live typing doesn't write the file on every keystroke. The pad is tiny
    /// (text), so the write itself is cheap.
    func updatePad(_ text: String) {
        guard padText != text else { return }
        liftPadBangLines(from: text)
        padText = text
        padSaveTask?.cancel()
        padSaveTask = Task { [id] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? MeetingStorage.writePad(text, for: id)
        }
    }

    /// Pad lift: a COMPLETED line starting `!` becomes an ad-hoc coach
    /// checklist item — one keystroke ahead of the thought, zero new UI.
    /// "Completed" = followed by a newline (the user pressed return), so
    /// the partial prefixes typed on the way ("!", "!bu", "!budget…")
    /// never lift. The pad text itself is left untouched; lifted bodies
    /// are remembered per session so edits elsewhere don't re-lift them.
    private func liftPadBangLines(from text: String) {
        guard let engine = coachEngine else { return }
        var lines = text.components(separatedBy: "\n")
        if !text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("!") else { continue }
            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let key = body.lowercased()
            guard !liftedPadLines.contains(key) else { continue }
            liftedPadLines.insert(key)
            engine.addAdHocItem(body)
        }
    }

    /// Write any pending pad text immediately — called when recording stops
    /// and when the pad's view goes away, so the debounce window can't eat
    /// the last keystrokes.
    func flushPad() {
        guard padSaveTask != nil else { return }
        padSaveTask?.cancel()
        padSaveTask = nil
        try? MeetingStorage.writePad(padText, for: id)
    }

    /// Persist the per-meeting one-off instruction (see `MeetingMeta.oneOffPrompt`).
    /// Empty/whitespace clears it. Kept around after the run so re-opening the
    /// "Tune this run" sheet pre-loads the previous instruction to iterate on.
    func setOneOffPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        guard meta.oneOffPrompt != newValue else { return }
        meta.oneOffPrompt = newValue
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
    }

    /// Persist a user edit to the notes markdown. Keeps the model/time/`isFinal`
    /// stamps from the existing notes — only the body changes. No-op when there
    /// are no notes to edit or the text is unchanged.
    func updateNotesMarkdown(_ markdown: String) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var notes = meta.notes, notes.markdown != trimmed else { return }
        notes.markdown = trimmed
        meta.notes = notes
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
    }

    // MARK: - Title editing

    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meta.title = trimmed
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
    }

    /// Rename a speaker. The id stays stable (transcript segments reference
    /// it) — only the user-visible displayName changes. Silent no-op for
    /// unknown ids or empty names.
    func renameSpeaker(id: String, to newDisplayName: String) {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = meta.speakers.firstIndex(where: { $0.id == id }) else { return }
        guard meta.speakers[idx].displayName != trimmed else { return }
        meta.speakers[idx].displayName = trimmed
        // A hand-typed name is authoritative — drop the "auto-detected" flag so
        // it loses the sparkle and a re-process never overwrites it. It also
        // propagates to the linked person, so the store learns corrections.
        // Renaming an UNLINKED speaker IS the people-store entry point: a
        // known person's name bridges a voice the matcher missed (different
        // room/mic) and this meeting's embedding gets stored under them; a
        // brand-new name creates the person on the spot — the post-pass only
        // learns names it had at processing time, and a hand-typed name is
        // the strongest naming signal in the system, so it must not be the
        // one path that leaves no record. Embedding may be nil (rename after
        // relaunch — speakerEmbeddings is in-memory only); the person is
        // still created and their voice gets learned via the name bridge
        // next time they're heard.
        meta.speakers[idx].nameInferred = false
        if let personID = meta.speakers[idx].personID {
            PeopleStore.shared.rename(id: personID, to: trimmed)
        } else if AppState.shared.settings.peopleRecognitionEnabled, !meta.speakers[idx].isMe {
            let store = PeopleStore.shared
            let embedding = speakerEmbeddings?[id]
            let modelID = ModelCatalog.defaultDiarization.id
            let sameName = store.peopleMatching(name: trimmed)
            if sameName.count == 1 {
                meta.speakers[idx].personID = sameName[0].id
                if let embedding {
                    store.recordObservation(personID: sameName[0].id, embedding: embedding, modelID: modelID)
                }
            } else if sameName.isEmpty {
                let person = store.createPerson(
                    name: trimmed,
                    embedding: embedding,
                    modelID: embedding != nil ? modelID : nil
                )
                meta.speakers[idx].personID = person.id
            }
            // Two+ same-named people: linking would guess — leave unlinked.
        }
        meta.speakersEditedAt = Date()
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
    }

    /// Update a speaker's colour (hex string). Same persistence shape as
    /// rename — meta.json round-trips immediately so the new colour
    /// survives a relaunch.
    func recolorSpeaker(id: String, hex: String) {
        guard let idx = meta.speakers.firstIndex(where: { $0.id == id }) else { return }
        guard meta.speakers[idx].colorHex != hex else { return }
        meta.speakers[idx].colorHex = hex
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
    }

    /// Merge one speaker into another — the manual fix for an over-split
    /// diarization (two chips that are really the same person). Every word
    /// attributed to `sourceID` in the transcript and the track-inspection
    /// data is re-attributed to `targetID`, the transcript's turns are
    /// rebuilt so the merged speech reads as continuous turns rather than
    /// alternating fragments, and `sourceID`'s chip disappears. Survives
    /// relaunch (files are rewritten) but not a Re-process, which re-runs
    /// diarization from scratch.
    func mergeSpeaker(id sourceID: String, into targetID: String) {
        guard sourceID != targetID,
              meta.speakers.contains(where: { $0.id == sourceID }),
              meta.speakers.contains(where: { $0.id == targetID }) else { return }

        // Transcript: re-attribute, then rebuild turns from the word level so
        // previously-alternating fragments coalesce. Old transcripts without
        // word timings fall back to a plain id swap.
        if let transcript = MeetingStorage.readTranscript(for: id) {
            let remapped = transcript.segments.map { seg -> MeetingTranscriptSegment in
                var s = seg
                if s.speakerId == sourceID { s.speakerId = targetID }
                return s
            }
            let rebuilt: [MeetingTranscriptSegment]
            if remapped.allSatisfy({ !($0.words ?? []).isEmpty }) {
                let words = remapped.flatMap { seg in
                    (seg.words ?? []).map {
                        SpeakerAttributedWord(start: $0.start, end: $0.end, text: $0.text, speakerId: seg.speakerId)
                    }
                }.sorted { $0.start < $1.start }
                rebuilt = MeetingProcessor.buildSegments(from: words)
            } else {
                rebuilt = remapped
            }
            try? MeetingStorage.writeTranscript(MeetingTranscript(segments: rebuilt), for: id)
        }

        // Track-inspection data: same re-attribution so the Tracks view
        // agrees with the transcript.
        if var inspection = MeetingStorage.readTrackInspection(for: id) {
            for i in inspection.mic.indices where inspection.mic[i].speakerId == sourceID {
                inspection.mic[i].speakerId = targetID
            }
            for i in inspection.system.indices where inspection.system[i].speakerId == sourceID {
                inspection.system[i].speakerId = targetID
            }
            try? MeetingStorage.writeTrackInspection(inspection, for: id)
        }

        meta.speakers.removeAll { $0.id == sourceID }
        meta.speakersEditedAt = Date()
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
        transcriptRevision += 1
        NSLog("[Dictator] Merged speaker \(sourceID) into \(targetID) for meeting \(id)")
    }

    // MARK: - Timer loop

    private func startTimerLoop() {
        timerTask?.cancel()
        let startedAt = Date()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 100 ms ≈ 10 fps — this is now the *sole* driver of the live
                // meters and elapsed time. It replaces the per-audio-buffer
                // `state` pushes (which ran ~100×/s and re-rendered the
                // transcript-bearing live view); 10 fps reads as live for a
                // level meter at a fraction of the main-actor churn.
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { break }
                guard case .recording = self.state else { break }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.state = .recording(
                    elapsed: elapsed,
                    micLevel: self.lastMicLevel,
                    sysLevel: self.lastSystemLevel
                )
            }
        }
    }

    private static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting on \(f.string(from: date))"
    }
}
