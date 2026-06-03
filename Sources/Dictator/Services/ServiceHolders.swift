import Foundation

/// Settings pane needs to trigger a manual download via the same service instance
/// the Pipeline uses, so model load is amortised. Holders are main-actor isolated
/// because both services run on the main actor.
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

@MainActor
enum ParakeetServiceHolder {
    static let shared = ParakeetService()
}

/// Meeting-dedicated Parakeet pipeline. Separate instance from
/// `ParakeetServiceHolder` (dictation) so meeting ASR runs on its own serial
/// `AsrManager` actor and a long post-pass can't block a dictation; it borrows
/// the dictation service's loaded weights when they're warm rather than loading
/// a second copy. See `MeetingParakeetService`.
@MainActor
enum MeetingParakeetServiceHolder {
    static let shared = MeetingParakeetService()
}

/// FluidAudio offline speaker-diarization pipeline. Loaded on demand by the
/// Meetings post-capture flow; the Models pane Verify button also reaches in
/// here so settings + pipeline share one warm model.
@MainActor
enum DiarizerServiceHolder {
    static let shared = DiarizerService()
}
