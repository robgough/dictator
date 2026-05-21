import Foundation
import Observation
import AVFoundation

/// Drives the per-row "test what Whisper hears" button in the Dictionary
/// pane. Records a short audio clip, runs it through the user's currently-
/// configured ASR engine, and exposes the transcript to whichever row
/// initiated the test so it can populate its `pattern` field.
///
/// Only one row at a time can hold the mic; subsequent clicks while a test
/// is in flight are ignored (or stop the recording, in the recording state).
/// Also defers to the main dictation pipeline — a live dictation always
/// wins over a Settings-side test session.
@MainActor
@Observable
final class DictionaryTester {
    static let shared = DictionaryTester()

    enum State: Equatable {
        case idle
        case warmingUp
        case recording(level: Float)
        case transcribing
    }

    /// Current state of the test session. Observed by `CompactDictionaryRow`
    /// so the mic button can render correctly per row.
    private(set) var state: State = .idle

    /// The row that owns the current session (or last completed one). nil
    /// when idle. Used by row views to filter — only the row whose id
    /// matches gets to consume the pending result.
    private(set) var activeRowID: UUID?

    /// The last successful transcript, paired with the row that asked for
    /// it. Cleared by `consumePendingResult()` after a row has applied it
    /// to its pattern field.
    private(set) var pendingResult: PendingResult?

    /// Most recent error message, surfaced in the UI as a transient note.
    /// Cleared on the next successful start.
    private(set) var lastError: String?

    private let recorder = AudioRecorder()
    private let whisper = TranscriptionServiceHolder.shared
    private let parakeet = ParakeetServiceHolder.shared

    /// Auto-stop timer — long-press-or-talk UX would be nicer but click-
    /// to-start with a hard timeout is simpler to implement and matches
    /// the "tap a button, say a word" mental model. Five seconds is
    /// comfortably long for a single word and short enough that an
    /// abandoned test self-recovers.
    private var autoStopTask: Task<Void, Never>?

    struct PendingResult: Equatable {
        let rowID: UUID
        let text: String
    }

    private init() {
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording = self.state {
                self.state = .recording(level: level)
            }
        }
        recorder.onReady = { [weak self] in
            guard let self else { return }
            self.state = .recording(level: 0)
            self.scheduleAutoStop()
        }
        recorder.onStartFailed = { [weak self] error in
            self?.lastError = "Mic error: \(error.localizedDescription)"
            self?.reset()
        }
        recorder.onUnexpectedStop = { [weak self] message in
            // Treat unexpected stop like end-of-recording so we still try
            // to transcribe whatever was captured before the failure —
            // and surface the device-change message as a note.
            self?.lastError = message
            self?.finishRecording()
        }
    }

    /// Begin a test session for the given row. No-ops if a session is
    /// already in flight (for this row or another), or if the main
    /// dictation pipeline is busy (we share the mic — can't run both).
    func start(for rowID: UUID) {
        guard case .idle = state else { return }
        lastError = nil
        pendingResult = nil
        guard MicPermission.status() == .authorized else {
            lastError = "Microphone access required. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }
        if AppState.shared.pipeline.state.isActive {
            lastError = "Dictation in progress — try again in a moment."
            return
        }
        activeRowID = rowID
        state = .warmingUp
        recorder.start()
    }

    /// Manually stop the in-flight recording and start transcription.
    /// Called when the user clicks the mic button a second time.
    func stop() {
        finishRecording()
    }

    /// Reset to idle. Called by the row after it has consumed a result
    /// or dismissed an error, so the mic icon resets across all rows.
    func reset() {
        autoStopTask?.cancel()
        autoStopTask = nil
        state = .idle
        activeRowID = nil
    }

    /// Called by the receiving row once it has applied `pendingResult.text`
    /// to its pattern field. Clears the slot so a subsequent test doesn't
    /// re-fire the same result.
    func consumePendingResult() {
        pendingResult = nil
        // Don't reset activeRowID — `state` is already .idle by the time
        // pendingResult is set, so the row sees a clean state.
    }

    /// Clear the transient error banner. Called when the user dismisses
    /// it, or implicitly on the next successful start.
    func dismissError() {
        lastError = nil
    }

    // MARK: - Private

    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            self?.finishRecording()
        }
    }

    private func finishRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil
        // If we were never recording (e.g. cancelled during warmup), just
        // tidy up the recorder and reset.
        guard case .recording = state else {
            _ = recorder.stop()
            reset()
            return
        }
        let samples = recorder.stop()
        // ~250ms minimum at 16kHz — anything shorter is almost certainly
        // a misclick, not a word.
        guard samples.count > 4_000 else {
            lastError = "Didn't catch anything — try again."
            reset()
            return
        }
        let capturedRowID = activeRowID
        state = .transcribing
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = AppState.shared.settings
            let asr: (engine: any ASREngine, modelID: String) = {
                switch settings.transcriptionEngine {
                case .whisper: return (self.whisper, settings.whisperModelID)
                case .parakeet: return (self.parakeet, settings.parakeetModelID)
                }
            }()
            do {
                let raw = try await asr.engine.transcribe(samples: samples, modelID: asr.modelID)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.lastError = "No speech detected — try again."
                } else if let id = capturedRowID {
                    self.pendingResult = PendingResult(rowID: id, text: trimmed)
                }
            } catch {
                self.lastError = "Transcribe failed: \(error.localizedDescription)"
            }
            self.reset()
        }
    }
}
