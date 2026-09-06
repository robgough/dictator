// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: Utils/WeightSanitizer.swift (port of mlx-lm gemma4.py sanitize()).
// Comments translated. The vision/audio tower drops are load-bearing here:
// the Hub checkpoints are multimodal, and we only build the text modules —
// any tower weights left in the dict would fail module-path validation.

import Foundation
import MLX

/// Cleans and remaps checkpoint weights to match the Swift module structure.
enum Gemma4WeightSanitizer {

    /// Detects Google's original BF16 export (vs an MLX-community
    /// pre-converted checkpoint) — Google's weights prefix keys with "model.".
    static func isGoogleFormat(_ weights: [String: MLXArray]) -> Bool {
        weights.keys.contains { $0.hasPrefix("model.") }
    }

    /// Sanitizes weights loaded from safetensors:
    /// - strips "model." prefixes
    /// - remaps "language_model.X" → "language_model.model.X"
    /// - drops rotary-embedding frequencies (recomputed at runtime)
    /// - drops vision/audio tower weights (text-only build)
    /// - transposes PyTorch Conv weights → MLX layout (Google format only)
    /// - splits fused MoE gate_up_proj into gate_proj + up_proj
    static func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let isGoogle = isGoogleFormat(weights)
        var sanitized: [String: MLXArray] = [:]

        for (key, value) in weights {
            // Skip quantization-clipping params (unused without clipped linears).
            if key.contains("input_max") || key.contains("input_min")
                || key.contains("output_max") || key.contains("output_min") {
                continue
            }

            // Skip rotary embeddings (pre-computed frequencies).
            if key.contains("rotary_emb") { continue }
            if key.contains(".rope.") && key.hasSuffix(".freqs") { continue }

            // Skip the audio tower — text-only build.
            if key.contains("audio_tower") || key.contains("embed_audio") { continue }

            // Skip the vision tower — text-only build.
            if key.contains("vision_tower") || key.contains("embed_vision") { continue }

            var newKey = key
            var newValue = value

            // Strip the "model." prefix.
            if newKey.hasPrefix("model.") {
                newKey = String(newKey.dropFirst("model.".count))
            }

            // Remap language_model paths (PyTorch → MLX module structure).
            // MLX-community weights already use "language_model.model.X";
            // PyTorch exports use "language_model.X" → insert "model.".
            if newKey.hasPrefix("language_model.") && !newKey.hasPrefix("language_model.model.") {
                let rest = String(newKey.dropFirst("language_model.".count))
                newKey = "language_model.model." + rest
            }

            // Conv2d: [out, in, H, W] → [out, H, W, in] for Google BF16 exports.
            // MLX-community checkpoints are already in MLX layout.
            if isGoogle && newKey.contains(".conv") && newKey.hasSuffix(".weight") && newValue.ndim == 4 {
                newValue = newValue.transposed(0, 2, 3, 1)
            }

            // Conv1d: [out, in, K] → [out, K, in] for Google BF16 exports.
            if isGoogle && newKey.contains(".conv") && newKey.hasSuffix(".weight") && newValue.ndim == 3 {
                newValue = newValue.transposed(0, 2, 1)
            }

            // MoE: experts.down_proj → experts.switch_glu.down_proj.weight
            if newKey.hasSuffix(".experts.down_proj") {
                newKey = newKey.replacingOccurrences(of: ".experts.down_proj", with: ".experts.switch_glu.down_proj.weight")
            }

            // MoE: fused experts.gate_up_proj → split gate_proj + up_proj.
            if newKey.hasSuffix(".experts.gate_up_proj") {
                let gateKey = newKey.replacingOccurrences(of: ".experts.gate_up_proj", with: ".experts.switch_glu.gate_proj.weight")
                let upKey = newKey.replacingOccurrences(of: ".experts.gate_up_proj", with: ".experts.switch_glu.up_proj.weight")

                let swapped = newValue.swappedAxes(-1, -2)
                let midDim = swapped.shape.last! / 2
                sanitized[gateKey] = swapped[.ellipsis, 0 ..< midDim].swappedAxes(-1, -2)
                sanitized[upKey] = swapped[.ellipsis, midDim...].swappedAxes(-1, -2)
                continue
            }

            sanitized[newKey] = newValue
        }

        return sanitized
    }
}
