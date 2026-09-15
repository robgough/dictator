import Foundation
import Observation

/// Voice input for the chat composer.
///
/// Deliberately *not* the dictation pipeline. Routing the composer's mic button
/// through `Pipeline.startRecording` meant a chat prompt paid for the whole
/// dictation machine: the mode's LLM formatting passes, a window-vision capture
/// and its inference, an Accessibility read of the focused field, a synthetic
/// ⌘V paste, and an entry in the dictation history. Every one of those is
/// wrong here — there is no document to paste into, no surrounding text worth
/// reading, and a screenshot of whatever is behind the chat window has nothing
/// to do with the question being asked. It was also slow, which is the opposite
/// of what a prompt box should be.
///
/// So this is the short path, in the same shape as the Settings "Test
/// microphone" button: record, transcribe, hand back text. The two
/// deterministic passes that genuinely help are kept — spoken cues, so "full
/// stop" and "new line" work the way they do everywhere else in the app, and
/// the user's dictionary, so names come out spelled right — because both are
/// instant and their absence would read as a bug.
@MainActor
@Observable
final class ChatDictation {
    enum Phase: Equatable {
        case idle
        /// Mic asked for but not yet producing samples. On Bluetooth this can
        /// last seconds, and saying so beats a dead-looking button.
        case warmingUp
        case recording
        case transcribing
    }

    private(set) var phase: Phase = .idle
    private(set) var level: Float = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var wired = false

    /// Called with the finished transcript and whether the user asked for it to
    /// be sent straight away (they pressed Send rather than just stopping).
    var onTranscript: ((_ text: String, _ send: Bool) -> Void)?

    /// Set by `finish(send:)` and read when the transcript lands.
    @ObservationIgnored private var sendWhenDone = false

    /// How long the current recording has been running, for the panel's timer.
    private(set) var startedAt: Date?

    var isActive: Bool { phase != .idle }

    /// Anything shorter than half a second at 16 kHz is a misclick, not speech.
    /// Same threshold the dictation pipeline uses.
    private static let minimumSamples = 8_000

    /// Begin recording. No-op if already busy.
    func begin() {
        guard phase == .idle else { return }
        start()
    }

    /// Stop and transcribe. `send` decides whether the composer sends the
    /// result immediately or leaves it in the box to edit.
    func finish(send: Bool) {
        guard phase == .recording || phase == .warmingUp else { return }
        sendWhenDone = send
        stopAndTranscribe()
    }

    /// Stops without transcribing — the window closed, or the user switched
    /// thread mid-sentence.
    func cancel() {
        guard phase != .idle else { return }
        recorder.cancelStart()
        _ = recorder.stop()
        phase = .idle
        level = 0
        startedAt = nil
        errorMessage = nil
    }

    private func start() {
        wireUp()
        errorMessage = nil
        level = 0
        phase = .warmingUp
        startedAt = Date()
        recorder.start()
    }

    private func stopAndTranscribe() {
        let samples = recorder.stop()
        level = 0
        startedAt = nil
        guard samples.count >= Self.minimumSamples else {
            phase = .idle
            errorMessage = "Too short — hold on a moment longer."
            return
        }
        phase = .transcribing
        Task { await transcribe(samples) }
    }

    private func transcribe(_ samples: [Float]) async {
        let settings = AppState.shared.settings
        let engine: any ASREngine
        let modelID: String
        switch settings.transcriptionEngine {
        case .whisper:
            engine = TranscriptionServiceHolder.shared
            modelID = settings.whisperModelID
        case .parakeet:
            engine = ParakeetServiceHolder.shared
            modelID = settings.parakeetModelID
        }

        do {
            try await engine.ensureLoaded(modelID: modelID)
            var text = try await engine.transcribe(samples: samples, modelID: modelID)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                phase = .idle
                errorMessage = "Didn't catch that."
                return
            }
            // Cues always on here: this is a prompt the user is speaking, not
            // text bound for someone else's document, so there's no mode to
            // consult and no reason to make them type punctuation they could
            // say.
            text = SpokenCues.apply(to: text)
            text = Vocabulary.apply(VocabularyStore.shared.entries, to: text)
            errorMessage = nil
            phase = .idle
            onTranscript?(text, sendWhenDone)
        } catch {
            phase = .idle
            errorMessage = "Couldn't transcribe that: \(error.localizedDescription)"
        }
    }

    private func wireUp() {
        guard !wired else { return }
        wired = true
        recorder.onLevel = { [weak self] level in self?.level = level }
        recorder.onReady = { [weak self] in
            guard let self, self.phase == .warmingUp else { return }
            self.phase = .recording
        }
        recorder.onStartFailed = { [weak self] error in
            self?.phase = .idle
            self?.errorMessage = error.localizedDescription
        }
        recorder.onUnexpectedStop = { [weak self] message in
            self?.phase = .idle
            self?.errorMessage = message
        }
    }
}
