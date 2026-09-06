import Foundation

// The two engine-selection enums, shared by both mac apps. They were carved out
// of `DictatorSettings` when Meetings became its own app: `MeetingsSettings`
// needs `LLMEngineKind` to seed its local provider, and the shared model
// catalog / manager code talks about `TranscriptionEngine` without wanting to
// pull in Dictator's whole settings struct.

/// Which speech-to-text engine the pipeline uses. Each engine has its own
/// model picker in Settings → Models; switching here is the cheap "pick the
/// faster / different-language engine" lever without affecting LLM or paste
/// behaviour.
enum TranscriptionEngine: String, Codable, Sendable, Hashable, CaseIterable {
    case whisper   // WhisperKit CoreML (Argmax)
    case parakeet  // Parakeet TDT via FluidAudio CoreML (Apple Neural Engine)
}

/// Which LLM backend the pipeline drives for the formatter / grammar / structure
/// passes and Assistant Mode. Switching here is the primary "do I want a local
/// LLM at all, and which one" lever.
///
/// `apple` uses the Apple Foundation Models framework — the system-resident
/// ~3B model that ships with Apple Intelligence. Zero in-process weights, but
/// requires the user to have Apple Intelligence enabled.
///
/// `mlx` uses a HuggingFace MLX checkpoint picked from `ModelCatalog.llmModels`
/// — the legacy path. The specific model is `llmModelID`.
///
/// `none` disables every LLM pass; raw Whisper transcripts ship straight through.
enum LLMEngineKind: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case apple
    case mlx
}

/// Resolves an `LLMEngineKind` + model id to a protocol-typed engine instance.
///
/// Lives here rather than on `DictatorSettings` because both mac apps need it:
/// Dictator drives it from its own settings, and Dictator Meetings' local-MLX
/// and Apple providers resolve their engines through the same holders. For MLX
/// the configured model id is written into the singleton before returning, so
/// any subsequent call loads the right checkpoint.
enum LocalLLM {
    @MainActor
    static func engine(kind: LLMEngineKind, modelID: String) -> (any LLMEngine)? {
        switch kind {
        case .none:
            return nil
        case .apple:
            return AppleFoundationLLMServiceHolder.shared
        case .mlx:
            let mlx = MLXLLMServiceHolder.shared
            mlx.modelID = modelID
            return mlx
        }
    }
}
