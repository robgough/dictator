import Foundation
import Observation

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
        case captured
        case loadingASR(progress: Double)
        case transcribingMic(progress: Double)
        case transcribingSystem(progress: Double)
        case loadingDiarizer(progress: Double)
        case diarizing(progress: Double)
        case merging
        case ready
        case failed(String)

        var isProcessing: Bool {
            switch self {
            case .loadingASR, .transcribingMic, .transcribingSystem,
                 .loadingDiarizer, .diarizing, .merging:
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

    private let recorder = MeetingAudioRecorder()
    private let micRecorder = MeetingMicRecorder()
    private let processor = MeetingProcessor()
    private var timerTask: Task<Void, Never>?
    private var lastMicLevel: Float = 0
    private var lastSystemLevel: Float = 0

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

    /// Construct from on-disk meta. Lands directly in `.ready`.
    init(from meta: MeetingMeta) {
        self.id = meta.id
        self.meta = meta
        self.state = .ready
    }

    // MARK: - Live recording

    /// Begin capture. The session takes care of probing screen-recording
    /// permission first; on denial it lands in `.failed`.
    func startRecording(preferredMicDevice: AudioDevice?) async {
        guard case .idle = state else { return }
        state = .warmingUp

        switch await ScreenRecordingPermission.probe() {
        case .granted:
            break
        case .notGranted:
            state = .failed("Dictator needs Screen Recording permission to capture meeting audio. Open System Settings to grant it, then try again.")
            return
        }

        recorder.onReady = { [weak self] in
            guard let self else { return }
            self.state = .recording(elapsed: 0, micLevel: 0, sysLevel: 0)
            self.startTimerLoop()
        }
        // System level updates land immediately so the HUD's right meter
        // tracks live audio output without waiting for the 250ms tick.
        recorder.onLevel = { [weak self] _, sys in
            guard let self else { return }
            self.lastSystemLevel = sys
            self.pushLevels()
        }
        recorder.onUnexpectedStop = { [weak self] reason in
            guard let self else { return }
            self.timerTask?.cancel()
            self.timerTask = nil
            self.state = .failed(reason)
        }
        micRecorder.onLevel = { [weak self] mic in
            guard let self else { return }
            self.lastMicLevel = mic
            self.pushLevels()
        }

        do {
            let folder = MeetingStorage.folder(for: id)
            try await recorder.start(folder: folder, preferredMicUID: nil)
            // Mic capture runs on its own AVCaptureSession alongside SCK —
            // SCK's `.microphone` output silently dropped buffers on this
            // test machine, so the proven dictation path owns mic capture
            // here. Failure to start mic isn't fatal: system-only recording
            // is still useful (and surfaces in the UI via didCaptureMic).
            do {
                try await micRecorder.start(
                    at: MeetingStorage.micURL(for: id),
                    preferredDevice: preferredMicDevice
                )
            } catch {
                NSLog("[Dictator] Meeting mic capture failed to start: \(error)")
            }
        } catch {
            state = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    /// Push the current levels into `.recording` without waiting for the
    /// next timer tick. Cheap — just rebuilds the enum payload.
    private func pushLevels() {
        guard case .recording(let elapsed, _, _) = state else { return }
        state = .recording(
            elapsed: elapsed,
            micLevel: lastMicLevel,
            sysLevel: lastSystemLevel
        )
    }

    /// Stop recording. Writes the meta.json with the final duration,
    /// transitions through `.stopping` → `.captured`, then kicks off the
    /// processor automatically.
    func stopRecording(parakeetModelID: String) async {
        guard state.isLive else { return }
        state = .stopping
        timerTask?.cancel()
        timerTask = nil
        // Tear down both recorders in parallel so we don't double the wait.
        async let systemStop: MeetingAudioRecorder.StopResult = recorder.stop()
        async let micStop: Void = micRecorder.stop()
        let systemResult = await systemStop
        await micStop
        // Reflect what actually landed on disk. SCStream owns the system
        // track; the parallel AVCaptureSession owns the mic.
        meta.audioFiles = MeetingMeta.AudioFiles(
            mic: micRecorder.didCapture ? MeetingStorage.micFilename : nil,
            system: systemResult.didCaptureSystem ? MeetingStorage.systemFilename : nil
        )
        meta.durationSeconds = systemResult.durationSeconds
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
        state = .captured
        await runProcessor(parakeetModelID: parakeetModelID)
    }

    // MARK: - Import / re-process

    /// Run (or re-run) the post-capture pipeline. Used after a fresh
    /// recording and from the "Process now" button on a meeting that
    /// crashed mid-process.
    func runProcessor(parakeetModelID: String) async {
        do {
            state = .loadingASR(progress: 0)
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
            state = .ready
        } catch {
            state = .failed("Transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Title editing

    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meta.title = trimmed
        try? MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
    }

    // MARK: - Timer loop

    private func startTimerLoop() {
        timerTask?.cancel()
        let startedAt = Date()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
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
