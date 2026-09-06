// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: TextModel/Gemma4LanguageModel.swift (port of mlx-lm gemma4
// language.py LanguageModel). Trimmed: TurboQuant cache selection and the
// MTP forwardWithIntermediates path. Comments translated.

import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXNN

/// Full Gemma 4 language model: text model + tied logit head + softcapping.
final class Gemma4LanguageModel: Module {
    let config: Gemma4TextConfig
    let finalLogitSoftcapping: Float?

    @ModuleInfo var model: Gemma4TextModel

    init(_ config: Gemma4TextConfig) {
        self.config = config
        self.finalLogitSoftcapping = config.finalLogitSoftcapping > 0 ? config.finalLogitSoftcapping : nil

        self._model.wrappedValue = Gemma4TextModel(config)
        super.init()
    }

    func callAsFunction(
        inputs: MLXArray? = nil,
        inputsEmbeds: MLXArray? = nil,
        cache: [KVCache?]? = nil,
        perLayerInputs: MLXArray? = nil
    ) -> MLXArray {
        var out = model(
            inputs: inputs,
            inputsEmbeds: inputsEmbeds,
            cache: cache,
            perLayerInputs: perLayerInputs
        )

        // Tied word embeddings: reuse embed_tokens as the output projection.
        out = model.embedTokens.asLinear(out)

        // Final logit softcapping.
        if let softcap = finalLogitSoftcapping {
            out = tanh(out / softcap) * softcap
        }

        return out
    }

    /// Creates the KV caches — one per concrete (non-shared) layer:
    /// a plain cache for full attention, a rotating cache bounded by the
    /// sliding window for sliding attention.
    func makeCache() -> [any KVCache] {
        var caches: [any KVCache] = []
        let layerTypes = config.resolvedLayerTypes
        let concreteLayers = Array(layerTypes[..<config.firstKvSharedLayerIdx])

        for layerType in concreteLayers {
            if layerType == "full_attention" {
                caches.append(KVCacheSimple())
            } else {
                caches.append(MLXLMCommon.RotatingKVCache(maxSize: config.slidingWindow, keep: 0))
            }
        }
        return caches
    }
}
