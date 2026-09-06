// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: TextModel/Gemma4Attention.swift (port of mlx-lm gemma4
// language.py Attention). Trimmed: TurboQuant quantized-KV fast path and the
// MTP-drafter `kvSharedOnly` mode (k/v projections are always present here).
// Comments translated.

import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXNN

/// Gemma 4 multi-head attention:
/// - `global_head_dim` for full attention, `head_dim` for sliding layers
/// - optional K=V (values are the raw k_proj output, pre-k_norm; 26B/31B)
/// - KV sharing for the trailing layers
/// - per-attention-type RoPE (standard for sliding, proportional for full)
/// - `attentionWithCacheUpdate()` so quantized KV caches keep working
final class Gemma4Attention: Module {
    let config: Gemma4TextConfig
    let layerIdx: Int
    let layerType: String
    let isSliding: Bool
    let headDim: Int
    let numHeads: Int
    let numKVHeads: Int
    let useKEqV: Bool
    let isKvSharedLayer: Bool
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear?
    @ModuleInfo(key: "v_proj") var vProj: Linear?
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm?
    @ModuleInfo(key: "v_norm") var vNorm: RMSNormNoScale?

    let rope: Gemma4RoPEWrapper

    init(_ config: Gemma4TextConfig, layerIdx: Int) {
        self.config = config
        self.layerIdx = layerIdx

        let layerTypes = config.resolvedLayerTypes
        self.layerType = layerTypes[layerIdx]
        self.isSliding = layerType == "sliding_attention"

        // Dynamic head_dim: global_head_dim applies to full attention.
        if !isSliding && config.globalHeadDim > 0 {
            self.headDim = config.globalHeadDim
        } else {
            self.headDim = config.headDim
        }

        let dim = config.hiddenSize
        self.numHeads = config.numAttentionHeads

        // K=V on full attention (26B/31B variants).
        self.useKEqV = config.attentionKEqV && !isSliding
        if useKEqV, let globalKvHeads = config.numGlobalKeyValueHeads {
            self.numKVHeads = globalKvHeads
        } else {
            self.numKVHeads = config.numKeyValueHeads
        }

        self.scale = 1.0

        // KV sharing. Decided before module construction: shared layers reuse
        // the source layer's cached K/V at inference and never compute their
        // own, so they get no k/v projections. The newer (QAT) conversions
        // drop those weights from the checkpoint outright — building the
        // modules here would fail the load with "k_proj.weight not found".
        let firstKvSharedLayerIdx = config.firstKvSharedLayerIdx
        self.isKvSharedLayer = layerIdx >= firstKvSharedLayerIdx && firstKvSharedLayerIdx > 0

        self._qProj.wrappedValue = Linear(dim, numHeads * headDim, bias: false)
        self._oProj.wrappedValue = Linear(numHeads * headDim, dim, bias: false)
        self._qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)

        if isKvSharedLayer {
            self._kProj.wrappedValue = nil
            self._vProj.wrappedValue = nil
            self._kNorm.wrappedValue = nil
            self._vNorm.wrappedValue = nil
        } else {
            self._kProj.wrappedValue = Linear(dim, numKVHeads * headDim, bias: false)
            if !useKEqV {
                self._vProj.wrappedValue = Linear(dim, numKVHeads * headDim, bias: false)
            } else {
                self._vProj.wrappedValue = nil
            }
            self._kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
            self._vNorm.wrappedValue = RMSNormNoScale(eps: config.rmsNormEps)
        }

        // RoPE variant for this attention type.
        let ropeTheta = config.ropeTheta(forLayerType: layerType)
        let ropeType = config.ropeType(forLayerType: layerType)
        let partialRotaryFactor = ropeType == "proportional" ? config.fullAttentionPartialRotaryFactor : 1.0

        self.rope = Gemma4RoPEFactory.create(
            dims: headDim,
            base: ropeTheta,
            traditional: false,
            ropeType: ropeType,
            partialRotaryFactor: partialRotaryFactor
        )

        super.init()
    }

    /// Forward pass with cross-layer KV-sharing support.
    ///
    /// When `sharedKV` is supplied (KV-shared layers running without a cache),
    /// the shared K/V are reused instead of recomputed through k_proj/v_proj —
    /// mirroring Python mlx-lm's `shared_kv` mechanism.
    ///
    /// Returns `(output, kv, offset)` so the text model can track per-layer
    /// intermediates for the sharing logic.
    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none,
        cache: KVCache? = nil,
        sharedKV: (keys: MLXArray, values: MLXArray)? = nil,
        sharedOffset: Int? = nil
    ) -> (output: MLXArray, kv: (keys: MLXArray, values: MLXArray), offset: Int) {
        let (B, L, _) = (x.dim(0), x.dim(1), x.dim(2))

        var queries = qProj(x).reshaped(B, L, numHeads, headDim)
        queries = qNorm(queries)
        queries = queries.transposed(0, 2, 1, 3)

        var keys: MLXArray
        var values: MLXArray
        var effectiveOffset: Int

        if let (sharedKeys, sharedValues) = sharedKV {
            // KV sharing without a cache: reuse K/V from an earlier layer.
            // They're already normalised, transposed, and RoPE'd.
            keys = sharedKeys
            values = sharedValues
            effectiveOffset = sharedOffset ?? 0
            queries = rope(queries, offset: effectiveOffset)

            let output = MLXFast.scaledDotProductAttention(
                queries: queries,
                keys: keys,
                values: values,
                scale: scale,
                mask: mask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
            return (oProj(output), (keys, values), effectiveOffset)

        } else if isKvSharedLayer, let cache = cache {
            // KV sharing with a cache (inference): reuse the existing cache.
            // IMPORTANT: cache.offset has already been advanced by L by the
            // concrete source layer (which ran before us in this same
            // forward). Our queries sit at global positions
            // [cache.offset - L, ..., cache.offset - 1], so RoPE must use
            // (cache.offset - L), not cache.offset.
            effectiveOffset = cache.offset - L
            queries = rope(queries, offset: effectiveOffset)

            // Read the decompressed K/V straight out of the cache. The cache
            // is always populated by the source concrete layer earlier in
            // this same forward; shared layers carry no k/v projections of
            // their own (see init), so there is no compute-our-own fallback.
            let state = cache.state
            guard state.count >= 2 else {
                fatalError("KV-shared layer \(layerIdx) ran before its source layer populated the cache")
            }
            let output = MLXFast.scaledDotProductAttention(
                queries: queries,
                keys: state[0],
                values: state[1],
                scale: scale,
                mask: mask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
            return (oProj(output), (state[0], state[1]), effectiveOffset)
        }

        // Non-shared: compute our own K/V.
        let kv = computeKV(x: x, B: B, L: L)
        keys = kv.keys; values = kv.values

        // Read the offset BEFORE attentionWithCacheUpdate() advances it.
        effectiveOffset = cache?.offset ?? 0

        // RoPE on queries AND keys.
        queries = rope(queries, offset: effectiveOffset)
        keys = rope(keys, offset: effectiveOffset)

        // attentionWithCacheUpdate() handles the cache update.
        let output = attentionWithCacheUpdate(
            queries: queries,
            keys: keys,
            values: values,
            cache: cache,
            scale: scale,
            mask: mask
        )
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return (oProj(output), (keys, values), effectiveOffset)
    }

    private func computeKV(
        x: MLXArray, B: Int, L: Int
    ) -> (keys: MLXArray, values: MLXArray) {
        guard let kProj, let kNorm, let vNorm else {
            fatalError("computeKV called on KV-shared layer \(layerIdx) — it has no k/v projections")
        }
        var keys = kProj(x).reshaped(B, L, numKVHeads, headDim)

        // K=V: values are the raw k_proj output (pre-k_norm).
        var values: MLXArray
        if useKEqV {
            values = keys
        } else {
            values = vProj!(x).reshaped(B, L, numKVHeads, headDim)
        }

        keys = kNorm(keys)
        values = vNorm(values)
        values = values.transposed(0, 2, 1, 3)

        // RoPE is applied by the caller with the correct cache offset.
        keys = keys.transposed(0, 2, 1, 3)

        return (keys, values)
    }
}
