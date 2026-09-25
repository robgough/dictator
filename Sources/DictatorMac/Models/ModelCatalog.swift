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
    /// Usable context window for this model (tokens). Used by
    /// `ConversationContextBudget` to size the per-conversation input budget
    /// before pre-call compaction kicks in. Never a YaRN-extended ceiling —
    /// we don't want to keep RoPE scaling configs in sync with the model.
    ///
    /// For most entries this is the model's native number. For the 256K-native
    /// models (Gemma 4 12B, Qwen 3.5) it is deliberately *below* native: this
    /// value is a RAM commitment, not a capability claim, because the KV cache
    /// it implies has to fit alongside the weights. Filling 256K on a dense
    /// 12B would need more memory than the weights themselves.
    let contextWindowTokens: Int
    /// Whether this model is good enough to power Meetings. Long-transcript
    /// note writing is the hardest LLM job in the app, and the smallest
    /// models drift off the transcript / invent structure badly enough that
    /// the notes aren't worth keeping — so meetings hard-block them rather
    /// than let users ship rubbish and then complain. `meetingsRecommendedLLMID`
    /// is the best of these; the others run with a quality caveat. Defaults
    /// to false so a new catalog entry is opt-in, not silently allowed.
    var meetingsCapable: Bool = false
    /// Superseded by a newer model in the same size class. Legacy entries stay
    /// in the catalog forever so that an existing install keeps working — the
    /// id is what's persisted in settings, and the weights are already on the
    /// user's disk. They're hidden from the pickers unless the user has this
    /// one selected or downloaded, so a fresh install never sees them but
    /// nobody's dictation silently breaks on update. See `selectableLLMModels`.
    var isLegacy: Bool = false
    /// This model can read an image, so it can supply window-vision context.
    ///
    /// **Set this only from a real test, never from the checkpoint's config.**
    /// Having a `vision_config` is not sufficient and not necessary-looking:
    /// Gemma 4 E4B is a multimodal checkpoint that loads fine for text and
    /// *fails outright* through `VLMModelFactory` (it hits the KV-shared
    /// layers-carry-no-k_proj bug that upstream fixed on the text path but not
    /// the vision one). Qwen 3.5 4B loads and answers, but answers badly enough
    /// to be worse than nothing — it returns ordinary words instead of proper
    /// nouns, which would pollute `DocumentTerms`.
    ///
    /// Verify with `scratch/vlm-vision-check` before flipping this on for a
    /// model, and read the output rather than just checking it didn't throw.
    ///
    /// Measured on a 1024px window grab: Qwen 3.5 9B reads a screenshot in 1.5s
    /// and drafts a reply from an email in 3.9s; Gemma 4 12B takes 3.7s and
    /// 4.1s for the same work and is no more accurate — it's slightly noisier
    /// on the terms task. 9B is the cheaper way to get this by some distance.
    ///
    /// Note `approxRAMMB` for a vision-capable model is its *VLM* load, which
    /// is what it always gets now (see `MLXLLMService.ensureLoaded`); reading an
    /// image then spikes well above that for the duration of the read — about
    /// +2.8 GB on the 9B — because image prefill is transient, not resident.
    var visionCapable: Bool = false
    /// This model can drive the Chat window: hold a multi-turn thread, decide
    /// when a tool is needed, call it with the right arguments, and — the part
    /// that actually separates models — *stop* calling and answer once it has
    /// the result.
    ///
    /// **Measured, never inferred**, same rule as `visionCapable`. Verify with
    /// `scratch/tool-call-check` before setting it.
    ///
    /// The measurement was a surprise and is worth recording, because it
    /// contradicts the obvious assumption that only big models can do this:
    /// **every current catalog model passes, down to Qwen 3.5 2B.** All four
    /// scenarios (no-arg tool, tool with an argument, a question needing no
    /// tool, and a chained question needing two different tools whose facts
    /// both have to survive into the answer) pass on 2B, 4B, 9B, E4B and 12B.
    /// Round-trip latency ranges from 0.4s (2B) to 4.8s (12B).
    ///
    /// What does NOT vary is whether the loop works; what varies is the prose.
    /// The 2B's answers are terse and it buries facts; the 9B writes the
    /// cleanest replies of the five. So this flag gates *capability*, not
    /// quality — the Models pane says which models chat best.
    ///
    /// Off where untested, not where measured-and-failed: Gemma 4 E2B was never
    /// run (it's the same QAT family as E4B, which passes, but "same family" is
    /// exactly the inference this flag exists to forbid), and the legacy
    /// entries are September-2024 models nobody should run an agent loop on.
    ///
    /// One caveat that cost a whole debugging cycle: this is only true when the
    /// conversation is rebuilt with structured `tool_calls` (see
    /// `ChatWireMessage`). Fed a bare `role: tool` message instead, both Gemma 4
    /// sizes loop forever — they never see the result.
    var chatCapable: Bool = false
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

/// Catalogue entry for a speaker-diarization engine. Two ship: FluidAudio's
/// offline pipeline (pyannote community-1 segmentation + WeSpeaker embeddings,
/// clustered) and NVIDIA's Nemotron 3 Diarization (end-to-end, no clustering).
/// `DiarizerService` branches on the id.
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
        // moondream's post-trained v3 (FluidAudio 0.17.3): same architecture,
        // languages and decoder contract, int8 encoder. Measured against v3 on
        // a 6-minute clip (scratch/nemotron-eval `asr`): 614 vs 477 MB on disk,
        // same speed (~400× realtime), same resident footprint — it doesn't
        // need a bigger machine than v3. It also drops the "um / uh" fillers v3
        // transcribes verbatim. The id is FluidAudio's folder name, as for v3.
        .init(id: "parakeet-ultra", displayName: "Parakeet Ultra", approxSizeMB: 615, approxRAMMB: 750, note: "A more accurate retrain of v3 — same 25 languages and speed, slightly larger download."),
    ]

    /// Speaker diarization. The ids are Dictator-side labels (FluidAudio takes
    /// no variant string) and are what `MeetingsSettings.diarizationModelID`
    /// persists.
    ///
    /// Nemotron's figures are measured (scratch/nemotron-eval, one hour of
    /// audio): 2.2s on the GPU, ~1 GB peak while it runs — against ~600 MB for
    /// pyannote, which it also runs for voiceprints (see `DiarizerService`), so
    /// its download includes pyannote's bundle.
    static let diarizationModels: [DiarizationModel] = [
        .init(
            id: "pyannote-community-1",
            displayName: "Speaker Diarization (pyannote community-1)",
            approxSizeMB: 110,
            approxRAMMB: 600,
            note: "Identifies who spoke when. Small and quick, but can merge similar voices or miss people talking over each other."
        ),
        .init(
            id: nemotronDiarizationID,
            displayName: "Nemotron 3 Diarization (NVIDIA)",
            approxSizeMB: 220,
            approxRAMMB: 1000,
            note: "More accurate, especially with several people or crosstalk. Tells apart up to 8 voices per track."
        ),
    ]

    static let nemotronDiarizationID = "nemotron-3-diarization"

    /// The embedding space speaker voiceprints live in, and the `modelID` they
    /// are filed under in `PeopleStore`. Deliberately NOT the active
    /// diarizer's id: Nemotron produces no embeddings, so `DiarizerService`
    /// gives its speakers WeSpeaker ones — the same space pyannote uses. Filing
    /// them under a different id would be actively destructive, because
    /// `PeopleStore.recordObservation` wipes a person's stored voiceprints when
    /// the model id changes; switching diarizer would erase everyone.
    static let voiceprintSpaceID = "pyannote-community-1"

    static let llmModels: [LLMModel] = [
        // Qwen 3.5 (March 2026). 3:1 linear-attention to full-attention layers,
        // which is why these hold long conversations far more cheaply than a
        // same-size dense model: the KV cache barely grows on the linear layers.
        // The checkpoints are multimodal (Qwen3_5ForConditionalGeneration, with
        // a vision_config); the text path drops the vision tower at load, so
        // resident RAM runs below the download size — which is why these
        // approxRAMMB figures look low next to the download column.
        //
        // 4B is measured (phys_footprint after a real load + generate: 2670 MB);
        // 2B and 9B are scaled from it by weight size, since measuring them
        // would mean pulling another 7.7 GB. Re-measure if either ever becomes
        // a default.
        .init(id: "mlx-community/Qwen3.5-2B-4bit", displayName: "Qwen 3.5 2B (4-bit)", approxSizeMB: 1750, approxRAMMB: 1600, note: "Snappy; the light option", contextWindowTokens: 65_536, chatCapable: true),
        .init(id: "mlx-community/Qwen3.5-4B-4bit", displayName: "Qwen 3.5 4B (4-bit)", approxSizeMB: 3060, approxRAMMB: 3000, note: "Recommended", contextWindowTokens: 65_536, chatCapable: true),
        .init(id: "mlx-community/Qwen3.5-9B-4bit", displayName: "Qwen 3.5 9B (4-bit)", approxSizeMB: 5980, approxRAMMB: 5900, note: "Higher quality, and reads screenshots", contextWindowTokens: 65_536, meetingsCapable: true, visionCapable: true, chatCapable: true),
        // Gemma 4 runs on mlx-swift-lm's native gemma4 / gemma4_unified
        // architectures (3.31.4+). The checkpoints are multimodal — download
        // size includes vision/audio towers that are dropped at load, so
        // resident RAM runs a little below what the file size suggests.
        //
        // NOTE ON VISION: E2B/E4B are NOT vision-capable in practice. E4B was
        // tested and fails to load through VLMModelFactory entirely (keyNotFound
        // on layers/24/self_attn/k_proj — the KV-shared-layer bug, unfixed on
        // the vision path); E2B is the same QAT shape and untested, so it stays
        // off. Of the Qwen 3.5 entries, 9B is tested and good; 4B is tested and
        // its output is unusable for this task (ordinary words, not proper
        // nouns); 2B is untested. Test before flipping any of these on.
        //
        // The E-series are the QAT (quantization-aware trained) releases —
        // noticeably better than the launch-day post-training quants at the
        // same bit width. E4B uses the MXFP4 conversion (faster kernels, group
        // size 32); E2B's MXFP4 repo was an empty upload when this was written
        // (rechecked 2026-09-15, still empty), so it ships the affine 4-bit QAT.
        .init(id: "mlx-community/gemma-4-E2B-it-qat-4bit", displayName: "Gemma 4 E2B QAT (4-bit)", approxSizeMB: 4400, approxRAMMB: 4000, note: "Gemini 3-derived; strong for its size", contextWindowTokens: 131_072, meetingsCapable: true),
        .init(id: "mlx-community/gemma-4-E4B-it-qat-mxfp4", displayName: "Gemma 4 E4B QAT (MXFP4)", approxSizeMB: 6700, approxRAMMB: 6200, note: "Best quality; recommended for Meetings", contextWindowTokens: 131_072, meetingsCapable: true, chatCapable: true),
        // Gemma 4 12B is the dense "unified" model: encoder-free multimodal,
        // 48 layers, full attention every 6th layer. It needs a 32 GB machine
        // to be comfortable, which is why no tier recommends it automatically —
        // measured at 10.9 GB resident after a load + generate, before you add
        // a transcription model and the rest of the system.
        //
        // Repo choice is deliberate. The QAT conversions quantize the MLP
        // gate/up/down projections to 8 bits (4-bit elsewhere), so they weigh
        // ~11 GB rather than the ~6.8 GB a uniform 4-bit quant would — this is
        // the affine QAT, the most-exercised of them. Alternates if it
        // disappoints: `-qat-mxfp4` (same size, faster kernels) and
        // `-qat-OptiQ-4bit` (~9 GB, sensitivity-aware mixed precision, but a
        // third-party toolkit and very new). Both want an A/B before shipping.
        .init(id: "mlx-community/gemma-4-12B-it-qat-4bit", displayName: "Gemma 4 12B QAT (4-bit)", approxSizeMB: 11020, approxRAMMB: 11000, note: "Highest quality; needs 32 GB", contextWindowTokens: 32_768, meetingsCapable: true, visionCapable: true, chatCapable: true),

        // Superseded (all September 2024 vintage). Kept so existing installs
        // keep working — see `isLegacy`. Hidden from the pickers unless
        // selected or already downloaded.
        .init(id: "mlx-community/Llama-3.2-1B-Instruct-4bit", displayName: "Llama 3.2 1B (4-bit)", approxSizeMB: 760, approxRAMMB: 1500, note: "Superseded by Qwen 3.5 2B", contextWindowTokens: 131_072, isLegacy: true),
        .init(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B (4-bit)", approxSizeMB: 1900, approxRAMMB: 2500, note: "Superseded by Qwen 3.5 4B", contextWindowTokens: 131_072, isLegacy: true),
        .init(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", displayName: "Qwen 2.5 3B (4-bit)", approxSizeMB: 1800, approxRAMMB: 2500, note: "Superseded by Qwen 3.5 4B", contextWindowTokens: 32_768, isLegacy: true),
        .init(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", displayName: "Qwen 2.5 7B (4-bit)", approxSizeMB: 4400, approxRAMMB: 5500, note: "Superseded by Qwen 3.5 9B", contextWindowTokens: 131_072, meetingsCapable: true, isLegacy: true),
    ]

    /// The models a picker should offer: everything current, plus any legacy
    /// model the user is actually on or has on disk. `selectedID` is passed in
    /// rather than read from settings so this stays usable from both apps.
    static func selectableLLMModels(selectedID: String, isDownloaded: (String) -> Bool) -> [LLMModel] {
        llmModels.filter { !$0.isLegacy || $0.id == selectedID || isDownloaded($0.id) }
    }

    /// Fallback context size when the active model id isn't in the catalog
    /// (defensive — covers the case where someone hand-edits settings to
    /// point at a model we don't know). 32K matches the smallest model
    /// currently shipping in the catalog.
    static let fallbackContextWindowTokens = 32_768

    static let defaultWhisper      = whisperModels[2]       // small.en
    static let defaultParakeet     = parakeetModels[0]      // v3 (multilingual)
    /// Looked up by id rather than by index — the list gets reordered whenever
    /// a generation lands, and an index silently pointing at the wrong model is
    /// exactly the kind of bug nobody notices until a user reports it.
    static let defaultLLM          = llm(id: "mlx-community/Qwen3.5-4B-4bit") ?? llmModels[0]

    /// The LLM meetings are tuned for and recommend. Long-transcript note
    /// writing is the hardest LLM job in the app — smaller models drift off
    /// the transcript, invent structure, or mangle attribution somewhere
    /// across an hour of audio. Meetings no longer *require* this model:
    /// the user can record/import with any configured engine (including the
    /// Apple Foundation model) and gets a non-blocking quality warning for
    /// anything else — see `DictatorSettings.meetingsUsingRecommendedLLM`
    /// and `MeetingsFeature.llmQualityNote`. It stays the default
    /// recommendation and the one model whose note quality we vouch for.
    static let meetingsRecommendedLLMID = "mlx-community/gemma-4-E4B-it-qat-mxfp4"

    /// Display name for the recommended meetings model, for user-facing copy.
    /// Falls back to the raw id defensively — the entry is in the catalog
    /// above, but a future catalog edit shouldn't crash the warning text.
    static var meetingsRecommendedLLMName: String {
        llm(id: meetingsRecommendedLLMID)?.displayName ?? meetingsRecommendedLLMID
    }
    static let defaultDiarization  = diarizationModels[0]   // pyannote

    static func whisper(id: String) -> WhisperModel? { whisperModels.first { $0.id == id } }
    static func parakeet(id: String) -> ParakeetModel? { parakeetModels.first { $0.id == id } }
    static func llm(id: String) -> LLMModel? { llmModels.first { $0.id == id } }
    static func diarization(id: String) -> DiarizationModel? { diarizationModels.first { $0.id == id } }

    /// What the first-run wizard recommends as the *MLX* "Recommended" LLM preset
    /// for a given machine. Lean machines get the smallest model, since pairing
    /// Qwen 3.5 4B (~3.7 GB) with a transcription model (~700 MB) puts an
    /// 8 GB Mac firmly into swap. Balanced and above get the 4B default.
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
            // 16 GB Macs: Qwen 3.5 2B adds ~2.3 GB on top of Parakeet's
            // ~700 MB, comfortably under half of system RAM with headroom.
            return "mlx-community/Qwen3.5-2B-4bit"
        case .generous:
            // 24 GB: the 4B model is the default and gives noticeably better
            // cleanup than 2B.
            return defaultLLM.id
        case .ample:
            // 32 GB and up: the 9B is better at everything the 4B does and is
            // the cheapest model that can read a screenshot (measured 5.9 GB
            // resident, ~+2.8 GB transiently while reading), so recommending it
            // here is also what makes screen reading reachable out of the box.
            // The 12B stays the user's call — twice the download for no
            // measured gain on our passes.
            return "mlx-community/Qwen3.5-9B-4bit"
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
