// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: TextModel/Gemma4MLP.swift, Gemma4Router.swift, Gemma4Experts.swift
// (ports of mlx-lm gemma4 language.py). Comments translated.
//
// The MoE pieces (router + experts) only activate for the 26B-A4B variant
// (`enable_moe_block`); the dense models (E2B/E4B/12B/31B) never construct
// them. Kept so a future 26B catalog entry is config-only.

import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Gemma 4 feed-forward, with double-wide support for KV-shared layers.
final class Gemma4MLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: Gemma4TextConfig, layerIdx: Int) {
        let firstKvSharedLayerIdx = config.firstKvSharedLayerIdx
        let isKvSharedLayer = layerIdx >= firstKvSharedLayerIdx && firstKvSharedLayerIdx > 0
        let useDoubleWide = config.useDoubleWideMlp && isKvSharedLayer
        let intermediateSize = config.intermediateSize * (useDoubleWide ? 2 : 1)

        self._gateProj.wrappedValue = Linear(config.hiddenSize, intermediateSize, bias: false)
        self._upProj.wrappedValue = Linear(config.hiddenSize, intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(intermediateSize, config.hiddenSize, bias: false)

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

/// MoE router: norm → scale → project → softmax → top-k → renormalize →
/// per-expert scale.
final class Gemma4Router: Module {
    let numExperts: Int
    let topK: Int
    let rootSize: Float

    let norm: RMSNormNoScale
    @ModuleInfo var proj: Linear
    @ModuleInfo var scale: MLXArray
    @ModuleInfo(key: "per_expert_scale") var perExpertScale: MLXArray

    init(_ config: Gemma4TextConfig) {
        self.numExperts = config.numExperts ?? 128
        self.topK = config.topKExperts ?? 8
        self.rootSize = pow(Float(config.hiddenSize), -0.5)

        self.norm = RMSNormNoScale(eps: config.rmsNormEps)
        self._proj.wrappedValue = Linear(config.hiddenSize, numExperts, bias: false)
        self._scale.wrappedValue = MLXArray.ones([config.hiddenSize])
        self._perExpertScale.wrappedValue = MLXArray.ones([numExperts])

        super.init()
    }

    /// Returns `(topKIndices, topKWeights)`.
    func callAsFunction(_ x: MLXArray) -> (MLXArray, MLXArray) {
        var h = norm(x)
        h = h * MLXArray(rootSize, dtype: h.dtype)
        h = h * scale

        let expertScores = proj(h)
        let routerProbs = softmax(expertScores, axis: -1)

        let topKIndices = MLX.argPartition(-expertScores, kth: topK - 1, axis: -1)[.ellipsis, ..<topK]

        var topKWeights = MLX.takeAlong(routerProbs, topKIndices, axis: -1)
        topKWeights = topKWeights / MLX.sum(topKWeights, axis: -1, keepDims: true)
        topKWeights = topKWeights * perExpertScale[topKIndices]

        return (topKIndices, topKWeights)
    }
}

/// Sparse MoE experts: thin wrapper around MLXLMCommon's SwitchGLU with the
/// GeGLU (gelu_approx) activation.
final class Gemma4Experts: Module {
    @ModuleInfo(key: "switch_glu") var switchGLU: SwitchGLU

    init(_ config: Gemma4TextConfig) {
        let numExperts = config.numExperts ?? 128

        self._switchGLU.wrappedValue = SwitchGLU(
            inputDims: config.hiddenSize,
            hiddenDims: config.moeIntermediateSize,
            numExperts: numExperts,
            activation: geluApproximate,
            bias: false
        )

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        topKIndices: MLXArray,
        topKWeights: MLXArray
    ) -> MLXArray {
        let (B, S, H) = (x.dim(0), x.dim(1), x.dim(2))
        let K = topKIndices.dim(-1)

        let xFlat = x.reshaped(B * S, H)
        let indicesFlat = topKIndices.reshaped(B * S, K)

        let expertOut = switchGLU(xFlat, indicesFlat)

        let weights = topKWeights.reshaped(B * S, K)[.ellipsis, .newAxis]
        return (expertOut * weights).sum(axis: -2).reshaped(B, S, H)
    }
}
