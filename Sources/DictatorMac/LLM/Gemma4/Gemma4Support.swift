// Vendored from VincentGourbin/gemma-4-swift-mlx (MIT) — text-only subset.
// Upstream: Norms/RMSNormNoScale.swift, Norms/RMSNormZeroShift.swift,
// RoPE/ProportionalRoPE.swift, RoPE/RoPEFactory.swift (ports of
// mlx-lm gemma4 language.py / rope_utils.py). Comments translated.

import Foundation
import MLX
import MLXFast
import MLXNN

/// RMSNorm without a learnable scale (parameter-free).
final class RMSNormNoScale: Module {
    let eps: Float

    init(eps: Float = 1e-6) {
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: MLXArray.mlxNone, eps: eps)
    }
}

/// Gemma 4's RMSNorm variant: the weight is applied directly (scale_shift = 0),
/// unlike MLXNN's standard RMSNorm which computes `weight * (1 + x)`.
final class RMSNormZeroShift: Module {
    @ModuleInfo var weight: MLXArray
    let eps: Float

    init(dimensions: Int, eps: Float = 1e-6) {
        self._weight.wrappedValue = MLXArray.ones([dimensions])
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: weight, eps: eps)
    }
}

/// Type-erasure for the two RoPE implementations.
protocol Gemma4RoPELayer {
    func callAsFunction(_ x: MLXArray, offset: Int) -> MLXArray
}

extension RoPE: Gemma4RoPELayer {}

/// ProportionalRoPE for Gemma 4's full-attention layers ("pruned RoPE"):
/// rotates only a fraction of each head's dimensions (partial_rotary_factor),
/// with frequencies computed relative to the full head dimension.
/// Deliberately NOT a Module — `freqs` is not a learnable parameter.
final class ProportionalRoPE: Gemma4RoPELayer {
    let dims: Int
    let traditional: Bool
    let rotatedDims: Int
    let freqs: MLXArray?

    init(
        dims: Int,
        traditional: Bool = false,
        base: Float = 10000.0,
        factor: Float = 1.0,
        partialRotaryFactor: Float = 1.0
    ) {
        self.dims = dims
        self.traditional = traditional

        let ropeAngles = Int(partialRotaryFactor * Float(dims) / 2.0)
        self.rotatedDims = 2 * ropeAngles

        if rotatedDims > 0 {
            let exponents = MLXArray(stride(from: Float(0), to: Float(rotatedDims), by: 2)) / Float(dims)
            self.freqs = factor * pow(MLXArray(base), exponents)
        } else {
            self.freqs = nil
        }
    }

    func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        guard rotatedDims > 0, let freqs = freqs else { return x }

        let head = x[.ellipsis, 0 ..< dims]
        let half = dims / 2

        // Split into left/right halves.
        let left = head[.ellipsis, 0 ..< half]
        let right = head[.ellipsis, half ..< dims]

        let rotHalf = rotatedDims / 2

        // Take the to-be-rotated slice of each half.
        let leftRot = left[.ellipsis, 0 ..< rotHalf]
        let rightRot = right[.ellipsis, 0 ..< rotHalf]

        // Concatenate into the rotation input.
        let toRotate = concatenated([leftRot, rightRot], axis: -1)

        let rotated = MLXFast.RoPE(
            toRotate,
            dimensions: rotatedDims,
            traditional: traditional,
            base: nil as Float?,
            scale: 1.0,
            offset: offset,
            freqs: freqs
        )

        // Recombine: each half = [rotated part, untouched passthrough].
        let newLeft: MLXArray
        if rotHalf < half {
            let rotLeft = rotated[.ellipsis, 0 ..< rotHalf]
            let passLeft = left[.ellipsis, rotHalf...]
            newLeft = concatenated([rotLeft, passLeft], axis: -1)
        } else {
            newLeft = rotated[.ellipsis, 0 ..< rotHalf]
        }

        let newRight: MLXArray
        if rotHalf < half {
            let rotRight = rotated[.ellipsis, rotHalf...]
            let passRight = right[.ellipsis, rotHalf...]
            newRight = concatenated([rotRight, passRight], axis: -1)
        } else {
            newRight = rotated[.ellipsis, rotHalf...]
        }

        let newHead = concatenated([newLeft, newRight], axis: -1)

        // Reattach any dims beyond `dims` from the original tensor.
        if x.shape.last! > dims {
            let tail = x[.ellipsis, dims...]
            return concatenated([newHead, tail], axis: -1)
        }

        return newHead
    }
}

/// Lightweight holder for a `Gemma4RoPELayer` (not a Module, so no parameter
/// registration).
final class Gemma4RoPEWrapper {
    let inner: any Gemma4RoPELayer

    init(_ inner: any Gemma4RoPELayer) {
        self.inner = inner
    }

    func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
        inner(x, offset: offset)
    }
}

/// Builds the right RoPE variant for an attention type.
enum Gemma4RoPEFactory {
    static func create(
        dims: Int,
        base: Float,
        traditional: Bool = false,
        ropeType: String = "default",
        partialRotaryFactor: Float = 1.0,
        factor: Float = 1.0
    ) -> Gemma4RoPEWrapper {
        if ropeType == "proportional" {
            return Gemma4RoPEWrapper(ProportionalRoPE(
                dims: dims,
                traditional: traditional,
                base: base,
                factor: factor,
                partialRotaryFactor: partialRotaryFactor
            ))
        }
        return Gemma4RoPEWrapper(RoPE(dimensions: dims, traditional: traditional, base: base))
    }
}
