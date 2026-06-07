// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: Pipeline/Gemma4LLMModel.swift + Pipeline/Gemma4Registration.swift.
// Trimmed: TurboQuant kvBits plumbing in newCache. Comments translated.

import Foundation
import MLX
import MLXFast
import MLXLLM
import MLXLMCommon
import MLXNN

/// Gemma 4 model conforming to mlx-swift-lm's `LLMModel`, so the standard
/// `LLMModelFactory.loadContainer` path can load it once the architecture is
/// registered (see `Gemma4Registration`). Fully qualified because Dictator's
/// ModelCatalog declares an unrelated `LLMModel` catalog-entry struct.
final class Gemma4LLMModel: Module, MLXLLM.LLMModel {
    @ModuleInfo(key: "language_model") var languageModel: Gemma4LanguageModel

    let config: Gemma4TextConfig
    let modelType: String

    var kvHeads: [Int]

    init(config: Gemma4TextConfig) {
        self.config = config
        self.modelType = config.modelType

        self._languageModel.wrappedValue = Gemma4LanguageModel(config)
        self.kvHeads = Array(repeating: config.numKeyValueHeads, count: config.numHiddenLayers)

        super.init()
    }

    // MARK: - LoRAModel conformance (required by LLMModel; Dictator never trains)

    var loraLayers: [Module] {
        languageModel.model.layers.map { $0 as Module }
    }

    // MARK: - LLMModel conformance

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let cacheArray: [KVCache?]? = cache?.map { $0 as KVCache? }
        return languageModel(inputs: inputs, cache: cacheArray)
    }

    func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        languageModel.makeCache()
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = Gemma4WeightSanitizer.sanitize(weights: weights)

        // KV-shared layers never compute their own K/V, so Gemma4Attention
        // builds no k/v projections for them. The QAT conversions drop those
        // weights from the checkpoint accordingly — but the launch-day PTQ
        // conversions still carry them as dead weights, and leaving them in
        // the dict trips weight-verification on parameters no module owns.
        let firstShared = config.firstKvSharedLayerIdx
        if firstShared < config.numHiddenLayers && firstShared > 0 {
            let prefix = "language_model.model.layers."
            let deadModules = ["k_proj", "v_proj", "k_norm", "v_norm"]
            sanitized = sanitized.filter { key, _ in
                guard key.hasPrefix(prefix) else { return true }
                let rest = key.dropFirst(prefix.count)
                guard let dot = rest.firstIndex(of: "."),
                      let layerIdx = Int(rest[..<dot]),
                      layerIdx >= firstShared else { return true }
                let tail = rest[rest.index(after: dot)...]
                return !deadModules.contains { tail.hasPrefix("self_attn.\($0).") }
            }
        }

        return sanitized
    }

    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int? = nil) throws -> PrepareResult {
        let promptTokens = input.text.tokens
        let promptCount = promptTokens.shape[0]

        guard promptCount > 0 else {
            let emptyToken = MLXArray(Int32(0))[0 ..< 0]
            return .tokens(.init(tokens: emptyToken))
        }

        return .tokens(input.text)
    }
}

/// Registers the `gemma4` / `gemma4_text` architectures in mlx-swift-lm's
/// shared type registry. mlx-swift-lm has no native Gemma 4 support yet
/// (ml-explore/mlx-swift-lm#207/#282); once it lands, delete this whole
/// folder and the `registerIfNeeded()` call in MLXLLMService.
///
/// Both model types build the *text* model only — the weight sanitizer drops
/// the vision/audio towers that multimodal checkpoints carry.
@MainActor
enum Gemma4Registration {
    private static var registered = false

    /// Idempotent; must complete before the first Gemma 4 `loadContainer`.
    /// Called from `MLXLLMService.ensureLoaded` so ordering is guaranteed
    /// without racing an app-startup Task.
    static func registerIfNeeded() async {
        guard !registered else { return }
        registered = true

        await LLMTypeRegistry.shared.registerModelType("gemma4_text") { @Sendable configData in
            let fullConfig = try JSONDecoder().decode(Gemma4Config.self, from: configData)
            return Gemma4LLMModel(config: fullConfig.textConfig)
        }
        await LLMTypeRegistry.shared.registerModelType("gemma4") { @Sendable configData in
            let fullConfig = try JSONDecoder().decode(Gemma4Config.self, from: configData)
            return Gemma4LLMModel(config: fullConfig.textConfig)
        }
    }
}
