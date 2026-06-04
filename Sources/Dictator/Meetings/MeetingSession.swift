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
    private(set) var state: State
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
    }

    /// Construct a session for an in-progress file import. Lands in
    /// `.importing(0)`; the caller drives `runImport` to do the
    /// background re-encode (which advances progress) and then chains
    /// into the post-capture processor.
    init(forImport meta: MeetingMeta) {
        self.id = meta.id
        self.meta = meta
        self.state = .importing(progress: 0)
    }

    /// Construct from on-disk meta. Lands in `.ready` if a transcript is
    /// already on disk; otherwise in `.captured` so the "Process now"
    /// button surfaces — covers the crash-mid-process case where audio
    /// + meta were written but the transcript stage never finished.
    init(from meta: MeetingMeta) {
        self.id = meta.id
        self.meta = meta
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
    func startRecording(preferredMicDevice: AudioDevice?) async {
        guard case .idle = state else { return }
        state = .warmingUp
        captureWarnings = []
        micHeard = false
        systemHeard = false

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
        }
        recorder.onUnexpectedStop = { [weak self] reason in
            guard let self else { return }
            self.timerTask?.cancel()
            self.timerTask = nil
            self.liveTranscriber?.stop()
            self.liveTranscriber = nil
            _ = self.notesAccumulator?.stop()
            self.notesAccumulator = nil
            AppState.shared.meetingRecordingStartedAt = nil
            self.state = .failed(reason)
        }
        recorder.onCaptureWarning = { [weak self] message in
            self?.upsertCaptureWarning(source: .system, message: message)
        }
        micRecorder.onLevel = { [weak self] mic in
            guard let self else { return }
            self.lastMicLevel = mic
            if mic > 0.02 { self.micHeard = true }
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

            // Live first-pass notes. Built from the live transcript, so they
            // only run when it's on. Opt-in (it runs the LLM during the call)
            // and only when an LLM is configured. Pulls from the same
            // transcriber the UI shows, so the notes track what the user is
            // watching take shape.
            if AppState.shared.settings.meetingLiveNotesEnabled,
               AppState.shared.settings.activeLLMEngine() != nil {
                let accumulator = MeetingNotesAccumulator(
                    transcriber: live,
                    settings: AppState.shared.settings
                )
                notesAccumulator = accumulator
                accumulator.start()
            }
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
        } catch {
            state = .failed("Couldn't start recording: \(error.localizedDescription)")
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
        // Tear down both recorders in parallel so we don't double the wait.
        async let systemStop: MeetingAudioRecorder.StopResult = recorder.stop()
        async let micStop: Void = micRecorder.stop()
        let systemResult = await systemStop
        await micStop
        // Tear down the live transcriber after the recorders so any final
        // buffers they enqueued get a chance to land before we cancel the
        // in-flight chunk task. The Parakeet weights themselves live in
        // `ParakeetServiceHolder.shared` and stay warm — the processor
        // about to run will reuse them immediately.
        // Finalise the live transcript + quick notes before tearing them down:
        // settle the held-back tail (the last couple of phrases) into the
        // transcript, then run one last notes pass so the quick notes are
        // complete. Persisted below (isFinal=false) so they survive even if the
        // post-capture notes pass doesn't run (auto-notes off) or fails; the
        // full pass overwrites them with isFinal=true when it succeeds.
        await liveTranscriber?.finishPending()
        let liveNotesMarkdown = ((await notesAccumulator?.finish()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        liveTranscriber?.stop()
        liveTranscriber = nil
        notesAccumulator = nil
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

            // When a notes rewrite is coming, go STRAIGHT into the notes
            // phase. Dropping to .ready here flashed the previous run's
            // notes for the several seconds the speaker-name + title passes
            // take, then yanked them away when the rewrite started —
            // "ready… no wait, loading again". One continuous flow instead;
            // the transcript stays readable throughout (.summarising keeps
            // TranscriptView on screen).
            let settings = AppState.shared.settings
            let llmAvailable = settings.activeLLMEngine() != nil
            let willWriteNotes = settings.meetingSummaryEnabled && llmAvailable
            state = willWriteNotes ? .summarising : .ready

            // Guess real speaker names from the conversation before titling or
            // writing notes, so both pick up "Rory" / "Pat" instead of
            // "Speaker 1". Conservative and non-destructive — only touches
            // default/previously-guessed labels, never a manual rename.
            if llmAvailable {
                await inferSpeakerNames(settings: settings)
            }

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

            // Optional auto-notes. The toggle is opt-in because the notes
            // pass is expensive on a long meeting and not every user wants
            // one; when it's off the user can still hit the "Generate" button
            // on the meeting detail view.
            if willWriteNotes {
                await generateNotes(settings: settings)
            }

            // Tell the user their notes are ready if they recorded and walked
            // away. Only for live recordings, and only when we're backgrounded
            // (if they're looking at the window they can already see it).
            if meta.source == .live, !NSApp.isActive {
                MeetingNotifier.notifyNotesReady(meetingTitle: meta.title)
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

    /// Run the title-suggestion LLM call and, if the suggestion passes
    /// the quality gate AND the current title is still the default
    /// date-format title, apply it. Failures are silent — the meeting
    /// just keeps its default title.
    private func maybeAutoRename(settings: DictatorSettings) async {
        guard MeetingSummaryService.isDefaultMeetingTitle(meta.title) else { return }
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
        } catch {
            NSLog("[Dictator] Meeting notes failed for \(id): \(error)")
            notesError = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't write the notes. Tap Generate to try again."
            state = .ready
        }
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
        // it loses the sparkle and a re-process never overwrites it.
        meta.speakers[idx].nameInferred = false
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
