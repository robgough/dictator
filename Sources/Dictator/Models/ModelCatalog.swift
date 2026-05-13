import Foundation

struct WhisperModel: Identifiable, Hashable, Sendable {
    let id: String          // WhisperKit model identifier (matches argmaxinc/whisperkit-coreml folder)
    let displayName: String
    let approxSizeMB: Int
    /// Approximate steady-state resident memory when this model is loaded.
    /// Surfaced as "≈X RAM" in the Models pane so the cost is visible up
    /// front. Figures match the marketing page's models table; reality
    /// varies slightly with the OS's compressed-memory accounting.
    let approxRAMMB: Int
    let note: String
}

struct LLMModel: Identifiable, Hashable, Sendable {
    let id: String          // HuggingFace repo id, e.g. mlx-community/Llama-3.2-3B-Instruct-4bit
    let displayName: String
    let approxSizeMB: Int
    /// Approximate steady-state resident memory when loaded at a modest
    /// context length. KV cache grows during long Assistant conversations,
    /// so the real number drifts upward — labelled "≈" in the UI.
    let approxRAMMB: Int
    let note: String
    /// Native context window for this model (tokens). Used by
    /// `ConversationContextBudget` to size the per-conversation input budget
    /// before pre-call compaction kicks in. We use the *native* number — not
    /// any YaRN-extended ceiling — so we don't have to keep RoPE scaling
    /// configs in sync with the model.
    let contextWindowTokens: Int
}

/// Catalogue entry for a Parakeet ASR variant. The `id` is also FluidAudio's
/// repo folder name (mirrors `AsrModelVersion.repo.folderName`), so it doubles
/// as the on-disk subdirectory under `ModelStorage.parakeetRoot()`.
struct ParakeetModel: Identifiable, Hashable, Sendable {
    let id: String          // e.g. "parakeet-tdt-0.6b-v3"
    let displayName: String
    let approxSizeMB: Int
    /// Approximate steady-state resident memory when loaded.
    let approxRAMMB: Int
    let note: String
}

enum ModelCatalog {
    /// Sentinel `llmModelID` that disables all LLM passes — the raw Whisper
    /// transcript is shipped straight through the dictionary substitution and
    /// out to the focused app. Useful on low-memory machines or when modern
    /// Whisper output is already good enough.
    static let noneLLMID = "none"

    static let whisperModels: [WhisperModel] = [
        .init(id: "openai_whisper-tiny.en", displayName: "Whisper Tiny (English)", approxSizeMB: 75, approxRAMMB: 150, note: "Fastest, lowest accuracy"),
        .init(id: "openai_whisper-base.en", displayName: "Whisper Base (English)", approxSizeMB: 140, approxRAMMB: 250, note: "Good balance for short utterances"),
        .init(id: "openai_whisper-small.en", displayName: "Whisper Small (English)", approxSizeMB: 470, approxRAMMB: 700, note: "Solid accuracy"),
        .init(id: "openai_whisper-large-v3-v20240930_turbo", displayName: "Whisper Large v3 Turbo", approxSizeMB: 1550, approxRAMMB: 2000, note: "Best quality, multilingual"),
    ]

    static let parakeetModels: [ParakeetModel] = [
        .init(id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT v3", approxSizeMB: 475, approxRAMMB: 700, note: "Multilingual — 25 European languages. ~60–70× realtime on Apple Silicon."),
        .init(id: "parakeet-tdt-0.6b-v2", displayName: "Parakeet TDT v2", approxSizeMB: 475, approxRAMMB: 700, note: "English-only, slightly better English WER than v3."),
    ]

    static let llmModels: [LLMModel] = [
        .init(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", displayName: "Llama 3.2 1B (4-bit)", approxSizeMB: 760, approxRAMMB: 1500, note: "Snappy, decent formatting", contextWindowTokens: 131_072),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B (4-bit)", approxSizeMB: 1900, approxRAMMB: 2500, note: "Recommended", contextWindowTokens: 131_072),
        .init(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen 2.5 3B (4-bit)", approxSizeMB: 1800, approxRAMMB: 2500, note: "Alt 3B option", contextWindowTokens: 32_768),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen 2.5 7B (4-bit)", approxSizeMB: 4400, approxRAMMB: 5500, note: "Higher quality, slower", contextWindowTokens: 131_072),
    ]

    /// Fallback context size when the active model id isn't in the catalog
    /// (defensive — covers the case where someone hand-edits settings to
    /// point at a model we don't know). 32K matches the smallest model
    /// currently shipping in the catalog.
    static let fallbackContextWindowTokens = 32_768

    static let defaultWhisper  = whisperModels[2]   // small.en
    static let defaultParakeet = parakeetModels[0]  // v3 (multilingual)
    static let defaultLLM      = llmModels[1]       // Llama 3.2 3B

    static func whisper(id: String) -> WhisperModel? { whisperModels.first { $0.id == id } }
    static func parakeet(id: String) -> ParakeetModel? { parakeetModels.first { $0.id == id } }
    static func llm(id: String) -> LLMModel? { llmModels.first { $0.id == id } }
}
