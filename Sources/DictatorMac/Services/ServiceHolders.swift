import Foundation

/// Shared, main-actor-isolated singletons for the model-backed services both
/// mac apps use. Settings panes need to trigger a manual download via the same
/// service instance the pipeline uses, so model load is amortised.
///
/// These live in `Sources/DictatorMac` — compiled into Dictator *and* Dictator
/// Meetings — which means each process gets its own copy of `shared`. That's
/// deliberate: the two apps don't share a heap, and cross-process model sharing
/// happens over the LLM socket, not through these holders.

/// WhisperKit CoreML transcription engine.
@MainActor
enum TranscriptionServiceHolder {
    static let shared = TranscriptionService()
}

/// MLX-Swift LLM engine. Holds the loaded ModelContainer for the user's currently
/// selected MLX model so Pipeline calls and Settings → Models verifies share the
/// same warm container.
@MainActor
enum MLXLLMServiceHolder {
    static let shared = MLXLLMService()
}

/// Apple Foundation Models LLM engine. Stateless wrapper — there's no in-process
/// model state to share, but we keep a singleton so its `isLoading` observable
/// can be read from both Settings UI and Pipeline.
@MainActor
enum AppleFoundationLLMServiceHolder {
    static let shared = AppleFoundationLLMService()
}

/// Parakeet TDT (FluidAudio, Apple Neural Engine) transcription engine — the
/// dictation instance. Meetings runs its own separate `AsrManager`; see
/// `MeetingParakeetServiceHolder`.
@MainActor
enum ParakeetServiceHolder {
    static let shared = ParakeetService()
}
