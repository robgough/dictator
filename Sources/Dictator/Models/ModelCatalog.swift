import Foundation

struct WhisperModel: Identifiable, Hashable, Sendable {
    let id: String          // WhisperKit model identifier (matches argmaxinc/whisperkit-coreml folder)
    let displayName: String
    let approxSizeMB: Int
    let note: String
}

struct LLMModel: Identifiable, Hashable, Sendable {
    let id: String          // HuggingFace repo id, e.g. mlx-community/Llama-3.2-3B-Instruct-4bit
    let displayName: String
    let approxSizeMB: Int
    let note: String
}

enum ModelCatalog {
    /// Sentinel `llmModelID` that disables all LLM passes — the raw Whisper
    /// transcript is shipped straight through the dictionary substitution and
    /// out to the focused app. Useful on low-memory machines or when modern
    /// Whisper output is already good enough.
    static let noneLLMID = "none"

    static let whisperModels: [WhisperModel] = [
        .init(id: "openai_whisper-tiny.en", displayName: "Whisper Tiny (English)", approxSizeMB: 75, note: "Fastest, lowest accuracy"),
        .init(id: "openai_whisper-base.en", displayName: "Whisper Base (English)", approxSizeMB: 140, note: "Good balance for short utterances"),
        .init(id: "openai_whisper-small.en", displayName: "Whisper Small (English)", approxSizeMB: 470, note: "Solid accuracy"),
        .init(id: "openai_whisper-large-v3-v20240930_turbo", displayName: "Whisper Large v3 Turbo", approxSizeMB: 1550, note: "Best quality, multilingual"),
    ]

    static let llmModels: [LLMModel] = [
        .init(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", displayName: "Llama 3.2 1B (4-bit)", approxSizeMB: 760, note: "Snappy, decent formatting"),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B (4-bit)", approxSizeMB: 1900, note: "Recommended"),
        .init(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen 2.5 3B (4-bit)", approxSizeMB: 1800, note: "Alt 3B option"),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen 2.5 7B (4-bit)", approxSizeMB: 4400, note: "Higher quality, slower"),
    ]

    static let defaultWhisper = whisperModels[2]   // small.en
    static let defaultLLM     = llmModels[1]        // Llama 3.2 3B

    static func whisper(id: String) -> WhisperModel? { whisperModels.first { $0.id == id } }
    static func llm(id: String) -> LLMModel? { llmModels.first { $0.id == id } }
}
