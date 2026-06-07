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

/// Catalogue entry for a speaker-diarization bundle. v0.2 ships a single
/// option (FluidAudio's offline pipeline built on pyannote community-1 +
/// WeSpeaker), but the catalog/manager shape mirrors Parakeet so we can grow
/// it later without rewriting the Settings UI.
struct DiarizationModel: Identifiable, Hashable, Sendable {
    let id: String          // catalogue id (also used as on-disk subdir under diarizationRoot())
    let displayName: String
    let approxSizeMB: Int
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

    /// Speaker diarization. The id is a Dictator-side label only — FluidAudio
    /// doesn't take a variant string, the offline pipeline is the one bundle
    /// it ships. We keep the indirection so future swaps (e.g. an LS-EEND
    /// streaming variant) don't break stored settings.
    static let diarizationModels: [DiarizationModel] = [
        .init(
            id: "pyannote-community-1",
            displayName: "Speaker Diarization (pyannote community-1)",
            approxSizeMB: 110,
            approxRAMMB: 600,
            note: "Identifies who spoke when. Runs after transcription on the system-audio track only — your microphone is always tagged as you."
        ),
    ]

    static let llmModels: [LLMModel] = [
        .init(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", displayName: "Llama 3.2 1B (4-bit)", approxSizeMB: 760, approxRAMMB: 1500, note: "Snappy, decent formatting", contextWindowTokens: 131_072),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B (4-bit)", approxSizeMB: 1900, approxRAMMB: 2500, note: "Recommended", contextWindowTokens: 131_072),
        .init(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen 2.5 3B (4-bit)", approxSizeMB: 1800, approxRAMMB: 2500, note: "Alt 3B option", contextWindowTokens: 32_768),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen 2.5 7B (4-bit)", approxSizeMB: 4400, approxRAMMB: 5500, note: "Higher quality, slower", contextWindowTokens: 131_072),
        // Gemma 4 runs on the vendored architecture in LLM/Gemma4/ (no native
        // mlx-swift-lm support yet). The checkpoints are multimodal — download
        // size includes vision/audio towers that are dropped at load, so
        // resident RAM runs a little below what the file size suggests.
        //
        // These are the QAT (quantization-aware trained) releases — noticeably
        // better than the launch-day post-training quants at the same bit
        // width. E4B uses the MXFP4 conversion (faster kernels, group size 32);
        // E2B's MXFP4 repo was empty at the time of adding, so it ships the
        // affine 4-bit QAT. If MXFP4 misbehaves, gemma-4-E4B-it-qat-4bit is
        // the like-for-like affine fallback.
        .init(id: "mlx-community/gemma-4-E2B-it-qat-4bit", displayName: "Gemma 4 E2B QAT (4-bit)", approxSizeMB: 4400, approxRAMMB: 4000, note: "Gemini 3-derived; strong for its size", contextWindowTokens: 131_072),
        .init(id: "mlx-community/gemma-4-E4B-it-qat-mxfp4", displayName: "Gemma 4 E4B QAT (MXFP4)", approxSizeMB: 6700, approxRAMMB: 6200, note: "Best quality; required for Meetings", contextWindowTokens: 131_072),
    ]

    /// Fallback context size when the active model id isn't in the catalog
    /// (defensive — covers the case where someone hand-edits settings to
    /// point at a model we don't know). 32K matches the smallest model
    /// currently shipping in the catalog.
    static let fallbackContextWindowTokens = 32_768

    static let defaultWhisper      = whisperModels[2]       // small.en
    static let defaultParakeet     = parakeetModels[0]      // v3 (multilingual)
    static let defaultLLM          = llmModels[1]           // Llama 3.2 3B

    /// The one LLM meetings are allowed to run with. Long-transcript note
    /// writing is the hardest LLM job in the app — every smaller catalog
    /// entry drifts off the transcript, invents structure, or mangles
    /// attribution somewhere across an hour of audio. Rather than let the
    /// feature quietly produce notes that aren't worth keeping, recording,
    /// importing, and (re)generating notes are gated on this exact model
    /// being the selected MLX LLM (`DictatorSettings.meetingsLLMSatisfied`).
    static let meetingsRequiredLLMID = "mlx-community/gemma-4-E4B-it-qat-mxfp4"

    /// Display name for the meetings requirement, for user-facing copy.
    /// Falls back to the raw id defensively — the entry is in the catalog
    /// above, but a future catalog edit shouldn't crash the alert text.
    static var meetingsRequiredLLMName: String {
        llm(id: meetingsRequiredLLMID)?.displayName ?? meetingsRequiredLLMID
    }
    static let defaultDiarization  = diarizationModels[0]   // only option in v0.2

    static func whisper(id: String) -> WhisperModel? { whisperModels.first { $0.id == id } }
    static func parakeet(id: String) -> ParakeetModel? { parakeetModels.first { $0.id == id } }
    static func llm(id: String) -> LLMModel? { llmModels.first { $0.id == id } }
    static func diarization(id: String) -> DiarizationModel? { diarizationModels.first { $0.id == id } }

    /// What the first-run wizard recommends as the *MLX* "Recommended" LLM preset
    /// for a given machine. Lean machines get the 1B model, since pairing
    /// Llama 3.2 3B (~2.5 GB) with a transcription model (~700 MB) puts an
    /// 8 GB Mac firmly into swap. Balanced and above get the 3B default.
    ///
    /// Returns `noneLLMID` for the very tightest machines — the wizard's
    /// "Recommended" segment then maps to "No LLM", which keeps total
    /// resident memory under a gigabyte.
    ///
    /// This is the per-MLX recommendation. The overall engine-level
    /// recommendation (which might pick Apple Foundation instead) is in
    /// `recommendedLLMEngine`.
    @MainActor
    static var recommendedLLMID: String {
        switch SystemMemory.tier {
        case .lean:
            // Under ~12 GB total RAM: running any LLM alongside the
            // transcription model is a tight squeeze. Default to None and
            // let the user opt in if they know what they're doing.
            return noneLLMID
        case .balanced:
            // 16 GB Macs: the 1B model adds ~1.5 GB on top of Parakeet's
            // ~700 MB, comfortably under half of system RAM with headroom.
            return llmModels[0].id  // Llama 3.2 1B
        case .generous:
            // ≥24 GB: the 3B model is the original default and gives
            // noticeably better cleanup than 1B.
            return defaultLLM.id
        }
    }

    /// One-shot recommendation for `(engine, mlxModelID)` based on what's actually
    /// usable on this machine right now. Two stored properties so the caller can
    /// surface the MLX pick alongside the engine recommendation (the Settings
    /// view shows it as a preview even when Apple is the default).
    struct LLMRecommendation {
        let engine: LLMEngineKind
        let mlxModelID: String?
    }

    /// What the first-run wizard recommends end-to-end. Prefers Apple's on-device
    /// Foundation Model when the user has Apple Intelligence enabled (zero disk,
    /// zero in-process RAM, quality bar comparable to a 3B class MLX model). Falls
    /// back to the RAM-tier MLX recommendation otherwise. Returns `.none` on the
    /// very leanest machines where even the smallest MLX model would push the
    /// system into swap.
    @MainActor
    static var recommendedLLMEngine: LLMRecommendation {
        if AppleFoundationAvailability.isUsable {
            return LLMRecommendation(engine: .apple, mlxModelID: recommendedLLMID == noneLLMID ? nil : recommendedLLMID)
        }
        let mlxPick = recommendedLLMID
        if mlxPick == noneLLMID {
            return LLMRecommendation(engine: .none, mlxModelID: nil)
        }
        return LLMRecommendation(engine: .mlx, mlxModelID: mlxPick)
    }
}
