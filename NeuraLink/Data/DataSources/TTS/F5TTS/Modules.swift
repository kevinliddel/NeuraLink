import Foundation
import MLX
import MLXNN

// Common modules for F5-TTS

final class SinusPositionEmbedding: Module {
    let dim: Int

    nonisolated override init() { fatalError("Use init(dim:)") }

    init(dim: Int) {
        self.dim = dim
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let halfDim = dim / 2
        let embScale: Float = Float(Foundation.log(10000.0)) / Float(halfDim - 1)
        let emb = MLX.exp(MLXArray(0..<halfDim).asType(.float32) * (-embScale))
        let embReshaped = x.expandedDimensions(axis: 1) * emb.expandedDimensions(axis: 0)
        return MLX.concatenated([MLX.sin(embReshaped), MLX.cos(embReshaped)], axis: -1)
    }
}

func applyRotaryPosEmb(t: MLXArray, freqs: MLXArray, scale: Float = 1.0) -> MLXArray {
    let rotDim = freqs.shape.last!
    let t_rot = t[.ellipsis, 0..<rotDim]
    let t_pass = t[.ellipsis, rotDim...]

    let cos_freqs = MLX.cos(freqs) * scale
    let sin_freqs = MLX.sin(freqs) * scale

    let t_rot_even = t_rot[.ellipsis, .stride(from: 0, to: rotDim, by: 2)]
    let t_rot_odd  = t_rot[.ellipsis, .stride(from: 1, to: rotDim, by: 2)]

    let rotated = MLX.concatenated([
        t_rot_even * cos_freqs - t_rot_odd * sin_freqs,
        t_rot_even * sin_freqs + t_rot_odd * cos_freqs
    ], axis: -1)

    return MLX.concatenated([rotated, t_pass], axis: -1)
}

final class GRN: Module {
    let gamma: MLXArray
    let beta: MLXArray

    nonisolated override init() { fatalError("Use init(dim:)") }

    init(dim: Int) {
        self.gamma = MLXArray.zeros([dim])
        self.beta = MLXArray.zeros([dim])
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let gx = sqrt(MLX.mean(pow(x, 2), axis: 1, keepDims: true))
        let nx = gx / (MLX.mean(gx, axis: -1, keepDims: true) + 1e-6)
        return x * (MLXArray(1) + gamma) * nx + beta
    }
}
