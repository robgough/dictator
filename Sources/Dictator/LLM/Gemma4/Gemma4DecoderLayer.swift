// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: TextModel/Gemma4DecoderLayer.swift (port of mlx-lm gemma4
// language.py DecoderLayer). Trimmed: MTP-drafter `kvSharedOnly` init flag.
// Comments translated.

import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXNN

/// Gemma 4 decoder layer: attention + dense MLP (+ parallel MoE experts on
/// 26B-A4B) + per-layer-input gating (E2B/E4B) + layer scalar.
final class Gemma4DecoderLayer: Module {
    let config: Gemma4TextConfig
    let layerIdx: Int
    let layerType: String
    let hiddenSizePerLayerInput: Int
    let enableMoe: Bool

    @ModuleInfo(key: "self_attn") var selfAttn: Gemma4Attention
    @ModuleInfo var mlp: Gemma4MLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayernorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayernorm: RMSNorm

    // MoE (26B-A4B): dense MLP + experts running in parallel branches.
    @ModuleInfo(key: "router") var router: Gemma4Router?
    @ModuleInfo(key: "experts") var experts: Gemma4Experts?
    @ModuleInfo(key: "post_feedforward_layernorm_1") var postFeedforwardLayernorm1: RMSNorm?
    @ModuleInfo(key: "pre_feedforward_layernorm_2") var preFeedforwardLayernorm2: RMSNorm?
    @ModuleInfo(key: "post_feedforward_layernorm_2") var postFeedforwardLayernorm2: RMSNorm?

    // Per-layer input gating (E2B/E4B).
    @ModuleInfo(key: "per_layer_input_gate") var perLayerInputGate: Linear?
    @ModuleInfo(key: "per_layer_projection") var perLayerProjection: Linear?
    @ModuleInfo(key: "post_per_layer_input_norm") var postPerLayerInputNorm: RMSNorm?

    // Layer scalar.
    @ModuleInfo(key: "layer_scalar") var layerScalar: MLXArray

    init(_ config: Gemma4TextConfig, layerIdx: Int) {
        self.config = config
        self.layerIdx = layerIdx
        self.layerType = config.resolvedLayerTypes[layerIdx]
        self.hiddenSizePerLayerInput = config.hiddenSizePerLayerInput
        self.enableMoe = config.enableMoeBlock

        self._selfAttn.wrappedValue = Gemma4Attention(config, layerIdx: layerIdx)
        self._mlp.wrappedValue = Gemma4MLP(config, layerIdx: layerIdx)

        self._inputLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._preFeedforwardLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postFeedforwardLayernorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        // MoE: router + experts + three extra layernorms.
        if enableMoe {
            self._router.wrappedValue = Gemma4Router(config)
            self._experts.wrappedValue = Gemma4Experts(config)
            self._postFeedforwardLayernorm1.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
            self._preFeedforwardLayernorm2.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
            self._postFeedforwardLayernorm2.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        } else {
            self._router.wrappedValue = nil
            self._experts.wrappedValue = nil
            self._postFeedforwardLayernorm1.wrappedValue = nil
            self._preFeedforwardLayernorm2.wrappedValue = nil
            self._postFeedforwardLayernorm2.wrappedValue = nil
        }

        // Per-layer input gating (only on models that carry per-layer inputs).
        if hiddenSizePerLayerInput > 0 {
            self._perLayerInputGate.wrappedValue = Linear(config.hiddenSize, hiddenSizePerLayerInput, bias: false)
            self._perLayerProjection.wrappedValue = Linear(hiddenSizePerLayerInput, config.hiddenSize, bias: false)
            self._postPerLayerInputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        } else {
            self._perLayerInputGate.wrappedValue = nil
            self._perLayerProjection.wrappedValue = nil
            self._postPerLayerInputNorm.wrappedValue = nil
        }

        self._layerScalar.wrappedValue = MLXArray.ones([1])

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none,
        cache: KVCache? = nil,
        perLayerInput: MLXArray? = nil,
        sharedKV: (keys: MLXArray, values: MLXArray)? = nil,
        sharedOffset: Int? = nil
    ) -> (output: MLXArray, kv: (keys: MLXArray, values: MLXArray), offset: Int) {
        var residual = x

        // Self-attention.
        var h = inputLayernorm(x)
        let (attnOut, kv, offset) = selfAttn(h, mask: mask, cache: cache, sharedKV: sharedKV, sharedOffset: sharedOffset)
        h = postAttentionLayernorm(attnOut)
        h = residual + h

        // Feed-forward: dense MLP (+ MoE experts in parallel on 26B-A4B).
        residual = h

        if enableMoe,
           let router = router,
           let experts = experts,
           let norm1 = postFeedforwardLayernorm1,
           let preNorm2 = preFeedforwardLayernorm2,
           let postNorm2 = postFeedforwardLayernorm2 {
            // Branch 1: dense MLP.
            var h1 = preFeedforwardLayernorm(h)
            h1 = mlp(h1)
            h1 = norm1(h1)

            // Branch 2: MoE experts.
            let (topKIndices, topKWeights) = router(h)
            var h2 = preNorm2(h)
            h2 = experts(h2, topKIndices: topKIndices, topKWeights: topKWeights)
            h2 = postNorm2(h2)

            // Combine both branches.
            h = h1 + h2
        } else {
            // Plain MLP (E2B, E4B, 12B, 31B).
            h = preFeedforwardLayernorm(h)
            h = mlp(h)
        }

        h = postFeedforwardLayernorm(h)
        h = residual + h

        // Per-layer input gating.
        if let gate = perLayerInputGate,
           let proj = perLayerProjection,
           let norm = postPerLayerInputNorm,
           let pli = perLayerInput {
            residual = h
            var gateOutput = gate(h)
            gateOutput = geluApproximate(gateOutput)
            gateOutput = gateOutput * pli
            gateOutput = proj(gateOutput)
            gateOutput = norm(gateOutput)
            h = residual + gateOutput
        }

        // Layer scalar.
        h = h * layerScalar

        return (h, kv, offset)
    }
}
