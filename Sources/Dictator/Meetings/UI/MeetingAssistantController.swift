import Foundation
import Observation

/// Drives the meeting "notes assistant" — the on-device assistant run against a
/// meeting's notes (ask a question → DRAFT answer; ask for an edit → REPLACE
/// preview you can apply). Pulled out of the sheet's `@State` into an
/// `@Observable` controller so the same flow can be driven two ways:
///   - the prominent Assistant button in the notes view (opens the dialog), and
///   - the global assistant hotkey when the Meetings window is focused
///     (`beginListening` on press, `endListeningAndRun` on release) — so it
///     works just like the main-app assistant, but on the conversation.
///
/// Owned by the notes view for the lifetime it's on screen, and registered with
/// `AppState.meetingAssistant` so the hotkey can find it.
@MainActor
@Observable
final class MeetingAssistantController {
    @ObservationIgnored private(set) weak var session: MeetingSession?

    /// Drives the assistant sheet's presentation.
    var isPresented = false
    /// The instruction being composed (typed and/or dictated).
    var instruction = ""
    /// The latest assistant reply, if any.
    var result: AssistantResult?
    var isRunning = false
    var errorText: String?
    var isListening = false
    var isTranscribing = false

    @ObservationIgnored private var recorder: AudioRecorder?

    func bind(session: MeetingSession) {
        guard self.session !== session else { return }
        self.session = session
        // New meeting → drop any stale reply/instruction so the dialog opens clean.
        instruction = ""
        result = nil
        errorText = nil
    }

    /// Whether there's anything for the assistant to act on right now — notes
    /// present and an LLM configured. The hotkey only routes here when true.
    var canRun: Bool {
        session?.meta.notes != nil && AppState.shared.settings.activeLLMEngine() != nil
    }

    var notesMarkdown: String { session?.meta.notes?.markdown ?? "" }
    var speakers: [MeetingMeta.Speaker] { session?.meta.speakers ?? [] }

    // MARK: - Entry points

    /// Open the dialog without starting to listen (the Assistant button).
    func present() {
        result = nil
        errorText = nil
        isPresented = true
    }

    /// Hotkey press: open the dialog and start listening immediately.
    func beginListening() {
        guard canRun else { return }
        isPresented = true
        guard !isListening, !isRunning, !isTranscribing else { return }
        startListening()
    }

    /// Hotkey release: stop listening and run the instruction against the notes.
    func endListeningAndRun() {
        guard isListening else { return }
        stopListening(thenRun: true)
    }

    /// The in-dialog mic button.
    func toggleListening() {
        isListening ? stopListening(thenRun: false) : startListening()
    }

    /// Apply a REPLACE-mode reply to the notes and close.
    func applyReplace() {
        guard let result, result.mode == .replace, let session else { return }
        session.updateNotesMarkdown(result.text)
        isPresented = false
    }

    /// Tear down the recorder when the dialog closes.
    func dialogClosed() {
        recorder?.stop()
        recorder = nil
        isListening = false
    }

    // MARK: - Voice input

    private func startListening() {
        let r = AudioRecorder()
        r.onStartFailed = { [weak self] _ in
            self?.errorText = "Couldn't access the microphone. Check Privacy & Security → Microphone."
            self?.isListening = false
            self?.recorder = nil
        }
        recorder = r
        errorText = nil
        result = nil
        isListening = true
        r.start()
    }

    private func stopListening(thenRun: Bool) {
        guard let r = recorder else { return }
        isListening = false
        recorder = nil
        let samples = r.stop()
        guard samples.count > 1600 else { return }   // < ~0.1s → nothing useful
        isTranscribing = true
        let settings = AppState.shared.settings
        let engine = settings.transcriptionEngine
        let asr: any ASREngine = engine == .whisper
            ? TranscriptionServiceHolder.shared
            : ParakeetServiceHolder.shared
        let modelID = engine == .whisper ? settings.whisperModelID : settings.parakeetModelID
        Task {
            do {
                try await asr.ensureLoaded(modelID: modelID)
                let text = try await asr.transcribe(samples: samples, modelID: modelID)
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    instruction = instruction.isEmpty ? t : instruction + " " + t
                }
            } catch {
                errorText = "Couldn't transcribe: \(error.localizedDescription)"
            }
            isTranscribing = false
            if thenRun { run() }
        }
    }

    // MARK: - LLM call

    func run() {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let engine = AppState.shared.settings.activeLLMEngine() else {
            errorText = "Turn on an LLM in Settings → Models to use the assistant."
            return
        }
        isRunning = true
        errorText = nil
        result = nil
        let prompt = AppState.shared.settings.effectiveAssistantPrompt
        let selection = notesMarkdown
        Task {
            do {
                try await engine.ensureReady()
                result = try await engine.assist(
                    selection: selection,
                    instruction: text,
                    systemPrompt: prompt,
                    priorTurns: [],
                    summary: nil,
                    cancellation: { false }
                )
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }
}
