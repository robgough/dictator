// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: TextModel/Gemma4TextModel.swift (port of mlx-lm gemma4
// language.py Gemma4TextModel). Trimmed: the MTP speculative-decoding
// surface (LayerIntermediate / TextForwardOutput / pre-norm capture) — the
// per-layer (kv, offset) bookkeeping that powers KV sharing is kept.
// Comments translated.

import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXNN

/// Linear with a baked-in scale factor (for per_layer_model_projection).
final class Gemma4ScaledLinear: Module {
    @ModuleInfo var weight: MLXArray
    let scalar: Float

    init(inFeatures: Int, outFeatures: Int, scalar: Float) {
        self._weight.wrappedValue = MLXArray.zeros([outFeatures, inFeatures])
        self.scalar = scalar
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        (matmul(x, weight.T)) * MLXArray(scalar, dtype: x.dtype)
    }
}

/// Gemma 4 text model (without the logit head).
final class Gemma4TextModel: Module {
    let config: Gemma4TextConfig
    let windowSize: Int
    let numHiddenLayers: Int
    let hiddenSizePerLayerInput: Int
    let firstKvSharedLayerIdx: Int
    let layerIdxToCacheIdx: [Int]
    let firstFullCacheIdx: Int
    let firstSlidingCacheIdx: Int

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [Gemma4DecoderLayer]
    @ModuleInfo var norm: RMSNorm

    // Per-layer input embeddings (E2B/E4B).
    @ModuleInfo(key: "embed_tokens_per_layer") var embedTokensPerLayer: Embedding?
    @ModuleInfo(key: "per_layer_model_projection") var perLayerModelProjection: Gemma4ScaledLinear?
    @ModuleInfo(key: "per_layer_projection_norm") var perLayerProjectionNorm: RMSNormZeroShift?

    let embedScale: Float
    let embedTokensPerLayerScale: Float
    let perLayerInputScale: Float

    init(_ config: Gemma4TextConfig) {
        self.config = config
        self.windowSize = config.slidingWindow
        self.numHiddenLayers = config.numHiddenLayers
        self.hiddenSizePerLayerInput = config.hiddenSizePerLayerInput
        self.firstKvSharedLayerIdx = config.firstKvSharedLayerIdx
        self.embedScale = pow(Float(config.hiddenSize), 0.5)
        self.embedTokensPerLayerScale = pow(Float(config.hiddenSizePerLayerInput), 0.5)
        self.perLayerInputScale = pow(2.0, -0.5)

        // layer_idx → cache_idx mapping. Only the concrete (non-shared)
        // layers own a cache; the trailing shared layers map back onto the
        // last concrete layer of the same attention type.
        let layerTypes = config.resolvedLayerTypes
        let concreteLayers = Array(layerTypes[..<firstKvSharedLayerIdx])

        var mapping = Array(0 ..< firstKvSharedLayerIdx)
        if firstKvSharedLayerIdx < config.numHiddenLayers {
            let sharedFullIdx = concreteLayers.lastIndex(of: "full_attention") ?? 0
            let sharedSlidingIdx = concreteLayers.lastIndex(of: "sliding_attention") ?? 0

            for i in firstKvSharedLayerIdx ..< config.numHiddenLayers {
                if layerTypes[i] == "full_attention" {
                    mapping.append(sharedFullIdx)
                } else {
                    mapping.append(sharedSlidingIdx)
                }
            }
        }
        self.layerIdxToCacheIdx = mapping

        // First cache index of each attention type (for mask construction).
        self.firstFullCacheIdx = concreteLayers.firstIndex(of: "full_attention") ?? 0
        self.firstSlidingCacheIdx = concreteLayers.firstIndex(of: "sliding_attention") ?? 0

        // Embeddings.
        self._embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabSize, dimensions: config.hiddenSize)

        // Layers.
        self._layers.wrappedValue = (0 ..< config.numHiddenLayers).map { i in
            Gemma4DecoderLayer(config, layerIdx: i)
        }

        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        // Per-layer input embeddings (E2B/E4B).
        if hiddenSizePerLayerInput > 0 {
            self._embedTokensPerLayer.wrappedValue = Embedding(
                embeddingCount: config.vocabSizePerLayerInput,
                dimensions: config.numHiddenLayers * config.hiddenSizePerLayerInput
            )
            self._perLayerModelProjection.wrappedValue = Gemma4ScaledLinear(
                inFeatures: config.hiddenSize,
                outFeatures: config.numHiddenLayers * config.hiddenSizePerLayerInput,
                scalar: pow(Float(config.hiddenSize), -0.5)
            )
            self._perLayerProjectionNorm.wrappedValue = RMSNormZeroShift(
                dimensions: config.hiddenSizePerLayerInput,
                eps: config.rmsNormEps
            )
        } else {
            self._embedTokensPerLayer.wrappedValue = nil
            self._perLayerModelProjection.wrappedValue = nil
            self._perLayerProjectionNorm.wrappedValue = nil
        }

        super.init()
    }

    // MARK: - Per-layer inputs

    func getPerLayerInputs(_ inputIds: MLXArray) -> MLXArray {
        guard let embed = embedTokensPerLayer else {
            fatalError("embed_tokens_per_layer not available")
        }
        var result = embed(inputIds)
        result = result * MLXArray(embedTokensPerLayerScale, dtype: result.dtype)
        let shape = inputIds.shape + [config.numHiddenLayers, hiddenSizePerLayerInput]
        return result.reshaped(shape)
    }

    func projectPerLayerInputs(_ inputsEmbeds: MLXArray, perLayerInputs: MLXArray?) -> MLXArray {
        guard let proj = perLayerModelProjection, let projNorm = perLayerProjectionNorm else {
            fatalError("per_layer_model_projection not available")
        }
        var perLayerProjection = proj(inputsEmbeds)
        let shape = Array(inputsEmbeds.shape.dropLast()) + [config.numHiddenLayers, hiddenSizePerLayerInput]
        perLayerProjection = perLayerProjection.reshaped(shape)
        perLayerProjection = projNorm(perLayerProjection)

        guard let perLayerInputs = perLayerInputs else {
            return perLayerProjection
        }

        return (perLayerProjection + perLayerInputs) * MLXArray(perLayerInputScale, dtype: inputsEmbeds.dtype)
    }

    // MARK: - Forward

    func callAsFunction(
        inputs: MLXArray? = nil,
        inputsEmbeds: MLXArray? = nil,
        cache: [KVCache?]? = nil,
        perLayerInputs: MLXArray? = nil
    ) -> MLXArray {
        var h: MLXArray
        if let inputsEmbeds = inputsEmbeds {
            h = inputsEmbeds
        } else if let inputs = inputs {
            h = embedTokens(inputs)
            h = h * MLXArray(embedScale, dtype: h.dtype)
        } else {
            fatalError("inputs or inputsEmbeds required")
        }

        // Per-layer inputs.
        var finalPerLayerInputs: MLXArray? = nil
        if hiddenSizePerLayerInput > 0 {
            var pli = perLayerInputs
            if inputs != nil && pli == nil {
                pli = getPerLayerInputs(inputs!)
            }
            if pli != nil || inputs != nil {
                finalPerLayerInputs = projectPerLayerInputs(h, perLayerInputs: pli)
            }
        }

        // Caches.
        let cacheArray = cache ?? Array(repeating: nil as KVCache?, count: firstKvSharedLayerIdx)

        // Attention masks — MLXLMCommon.createAttentionMask():
        // single tokens (T=1) get .none (no materialised mask), multi-token
        // prefill gets .causal or .array as appropriate.
        let globalMask = MLXLMCommon.createAttentionMask(
            h: h,
            cache: firstFullCacheIdx < cacheArray.count ? cacheArray[firstFullCacheIdx] : nil
        )
        let slidingWindowMask = MLXLMCommon.createAttentionMask(
            h: h,
            cache: firstSlidingCacheIdx < cacheArray.count ? cacheArray[firstSlidingCacheIdx] : nil,
            windowSize: windowSize
        )

        // Forward through the layers, tracking per-layer (kv, offset) so the
        // trailing KV-shared layers can reuse them when running cache-less.
        // Ref: Python mlx-lm gemma4_text.py (intermediates[] + previous_kvs).
        let layerTypes = config.resolvedLayerTypes
        var intermediates: [(kv: (keys: MLXArray, values: MLXArray), offset: Int)?] =
            Array(repeating: nil, count: numHiddenLayers)

        for (i, layer) in layers.enumerated() {
            let cacheIdx = layerIdxToCacheIdx[i]
            let c = cacheIdx < cacheArray.count ? cacheArray[cacheIdx] : nil
            let isGlobal = layerTypes[i] == "full_attention"

            let localMask = isGlobal ? globalMask : slidingWindowMask

            let perLayerInput: MLXArray?
            if let fpli = finalPerLayerInputs {
                perLayerInput = fpli[0..., 0..., i, 0...]
            } else {
                perLayerInput = nil
            }

            // KV sharing: hand the source layer's K/V to the shared layers
            // (only when there's no cache — with a cache, the cache itself
            // carries the sharing at inference time).
            let sharedKV: (keys: MLXArray, values: MLXArray)?
            let sharedOffset: Int?
            if i >= firstKvSharedLayerIdx && firstKvSharedLayerIdx > 0 && cache == nil,
               let prev = intermediates[cacheIdx] {
                sharedKV = prev.kv
                sharedOffset = prev.offset
            } else {
                sharedKV = nil
                sharedOffset = nil
            }

            let (output, kv, offset) = layer(
                h, mask: localMask, cache: c, perLayerInput: perLayerInput,
                sharedKV: sharedKV, sharedOffset: sharedOffset
            )
            h = output
            intermediates[i] = (kv: kv, offset: offset)
        }

        return norm(h)
    }
}
