// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// https://github.com/VincentGourbin/gemma-4-swift-mlx
// Upstream: Configuration/Gemma4TextConfig.swift + Configuration/Gemma4Config.swift
// (itself a port of mlx-vlm/models/gemma4/config.py). Trimmed: vision/audio
// sub-configs and multimodal token ids. Comments translated to English.
//
// Delete the Gemma4/ folder (and its registration call) once mlx-swift-lm
// ships native gemma4 support — tracked upstream as ml-explore/mlx-swift-lm
// #207 / #282 and ml-explore/mlx-swift #389.

import Foundation

/// RoPE parameters per attention type ("full_attention" / "sliding_attention").
struct Gemma4RoPEParameters: Codable {
    let ropeTheta: Float
    let ropeType: String
    let partialRotaryFactor: Float?

    enum CodingKeys: String, CodingKey {
        case ropeTheta = "rope_theta"
        case ropeType = "rope_type"
        case partialRotaryFactor = "partial_rotary_factor"
    }
}

/// Gemma 4 text-model configuration (the `text_config` block of a multimodal
/// checkpoint, or the root config of a text-only conversion).
struct Gemma4TextConfig: Codable {
    let modelType: String
    let hiddenSize: Int
    let numHiddenLayers: Int
    let intermediateSize: Int
    let numAttentionHeads: Int
    let headDim: Int
    let globalHeadDim: Int
    let rmsNormEps: Float
    let vocabSize: Int
    let numKeyValueHeads: Int
    let numGlobalKeyValueHeads: Int?
    let numKvSharedLayers: Int
    let hiddenSizePerLayerInput: Int
    let vocabSizePerLayerInput: Int
    let slidingWindow: Int
    let slidingWindowPattern: Int
    let maxPositionEmbeddings: Int
    let ropeParameters: [String: Gemma4RoPEParameters]?
    let finalLogitSoftcapping: Float
    let layerTypes: [String]?
    let attentionBias: Bool
    let attentionKEqV: Bool
    let useDoubleWideMlp: Bool
    let enableMoeBlock: Bool
    let numExperts: Int?
    let topKExperts: Int?
    let moeIntermediateSize: Int
    let tieWordEmbeddings: Bool

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case numAttentionHeads = "num_attention_heads"
        case headDim = "head_dim"
        case globalHeadDim = "global_head_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabSize = "vocab_size"
        case numKeyValueHeads = "num_key_value_heads"
        case numGlobalKeyValueHeads = "num_global_key_value_heads"
        case numKvSharedLayers = "num_kv_shared_layers"
        case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
        case vocabSizePerLayerInput = "vocab_size_per_layer_input"
        case slidingWindow = "sliding_window"
        case slidingWindowPattern = "sliding_window_pattern"
        case maxPositionEmbeddings = "max_position_embeddings"
        case ropeParameters = "rope_parameters"
        case finalLogitSoftcapping = "final_logit_softcapping"
        case layerTypes = "layer_types"
        case attentionBias = "attention_bias"
        case attentionKEqV = "attention_k_eq_v"
        case useDoubleWideMlp = "use_double_wide_mlp"
        case enableMoeBlock = "enable_moe_block"
        case numExperts = "num_experts"
        case topKExperts = "top_k_experts"
        case moeIntermediateSize = "moe_intermediate_size"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decode(String.self, forKey: .modelType)
        hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
        numHiddenLayers = try c.decode(Int.self, forKey: .numHiddenLayers)
        intermediateSize = try c.decode(Int.self, forKey: .intermediateSize)
        numAttentionHeads = try c.decode(Int.self, forKey: .numAttentionHeads)
        headDim = try c.decode(Int.self, forKey: .headDim)
        globalHeadDim = try c.decodeIfPresent(Int.self, forKey: .globalHeadDim) ?? 0
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        vocabSize = try c.decode(Int.self, forKey: .vocabSize)
        numKeyValueHeads = try c.decode(Int.self, forKey: .numKeyValueHeads)
        numGlobalKeyValueHeads = try c.decodeIfPresent(Int.self, forKey: .numGlobalKeyValueHeads)
        numKvSharedLayers = try c.decodeIfPresent(Int.self, forKey: .numKvSharedLayers) ?? 0
        hiddenSizePerLayerInput = try c.decodeIfPresent(Int.self, forKey: .hiddenSizePerLayerInput) ?? 0
        vocabSizePerLayerInput = try c.decodeIfPresent(Int.self, forKey: .vocabSizePerLayerInput) ?? 0
        slidingWindow = try c.decodeIfPresent(Int.self, forKey: .slidingWindow) ?? 512
        slidingWindowPattern = try c.decodeIfPresent(Int.self, forKey: .slidingWindowPattern) ?? 5
        maxPositionEmbeddings = try c.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131072
        ropeParameters = try c.decodeIfPresent([String: Gemma4RoPEParameters].self, forKey: .ropeParameters)
        finalLogitSoftcapping = try c.decodeIfPresent(Float.self, forKey: .finalLogitSoftcapping) ?? 30.0
        layerTypes = try c.decodeIfPresent([String].self, forKey: .layerTypes)
        attentionBias = try c.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        attentionKEqV = try c.decodeIfPresent(Bool.self, forKey: .attentionKEqV) ?? false
        useDoubleWideMlp = try c.decodeIfPresent(Bool.self, forKey: .useDoubleWideMlp) ?? false
        enableMoeBlock = try c.decodeIfPresent(Bool.self, forKey: .enableMoeBlock) ?? false
        numExperts = try c.decodeIfPresent(Int.self, forKey: .numExperts)
        topKExperts = try c.decodeIfPresent(Int.self, forKey: .topKExperts)
        moeIntermediateSize = try c.decodeIfPresent(Int.self, forKey: .moeIntermediateSize) ?? 0
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
    }

    /// Resolved per-layer attention types (generates the repeating
    /// sliding/full pattern when the config doesn't list them explicitly).
    var resolvedLayerTypes: [String] {
        if let lt = layerTypes { return lt }
        var pattern = Array(repeating: "sliding_attention", count: slidingWindowPattern - 1)
        pattern.append("full_attention")
        var result: [String] = []
        while result.count < numHiddenLayers {
            result.append(contentsOf: pattern)
        }
        return Array(result.prefix(numHiddenLayers))
    }

    /// Index of the first KV-shared layer.
    var firstKvSharedLayerIdx: Int {
        numHiddenLayers - numKvSharedLayers
    }

    /// RoPE theta for a given attention type.
    func ropeTheta(forLayerType type: String) -> Float {
        let key = type == "full_attention" ? "full_attention" : "sliding_attention"
        return ropeParameters?[key]?.ropeTheta ?? 10000.0
    }

    /// RoPE type for a given attention type ("default" or "proportional").
    func ropeType(forLayerType type: String) -> String {
        let key = type == "full_attention" ? "full_attention" : "sliding_attention"
        return ropeParameters?[key]?.ropeType ?? "default"
    }

    /// Partial rotary factor for full attention (pruned RoPE).
    var fullAttentionPartialRotaryFactor: Float {
        ropeParameters?["full_attention"]?.partialRotaryFactor ?? 1.0
    }
}

/// Top-level Gemma 4 config. The checkpoints on the Hub are multimodal —
/// `text_config` nested under vision/audio siblings — while text-only
/// conversions put the text fields at the root. This decoder handles both;
/// the vision/audio blocks are ignored entirely (we only load the text model).
struct Gemma4Config: Codable {
    let modelType: String
    let textConfig: Gemma4TextConfig

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case textConfig = "text_config"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try container.decode(String.self, forKey: .modelType)

        if container.contains(.textConfig) {
            textConfig = try container.decode(Gemma4TextConfig.self, forKey: .textConfig)
        } else {
            // Text-only conversion: decode the text fields from the root.
            textConfig = try Gemma4TextConfig(from: decoder)
        }
    }
}
