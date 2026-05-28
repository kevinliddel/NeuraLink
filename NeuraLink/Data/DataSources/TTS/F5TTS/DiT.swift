import Foundation
import MLX
import MLXNN

// Diffusion Transformer (DiT) implementation for F5-TTS

// Class names preserve the upstream F5-TTS naming (underscored suffixes
// distinguish F5-specific variants of generic blocks) so weight-loading
// against the reference checkpoints stays unambiguous.
// swiftlint:disable:next type_name
final class ConvNeXtBlock_F5: Module {
    let dwconv: GroupableConv1d
    let norm: LayerNorm
    let pwconv1: Linear
    let act: GELU
    let grn: GRN
    let pwconv2: Linear

    nonisolated override init() { fatalError("Use init(dim:intermediateDim:)") }

    init(dim: Int, intermediateDim: Int, dilation: Int = 1) {
        let padding = (dilation * (7 - 1)) / 2
        self.dwconv = GroupableConv1d(inputChannels: dim, outputChannels: dim, kernelSize: 7, padding: padding, groups: dim)
        self.norm = LayerNorm(dimensions: dim, eps: 1e-6)
        self.pwconv1 = Linear(dim, intermediateDim)
        self.act = GELU()
        self.grn = GRN(dim: intermediateDim)
        self.pwconv2 = Linear(intermediateDim, dim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let residual = x
        var out = dwconv(x)
        out = norm(out)
        out = pwconv1(out)
        out = act(out)
        out = grn(out)
        out = pwconv2(out)
        return residual + out
    }
}

final class AdaLayerNormZero: Module {
    let silu: SiLU = SiLU()
    let linear: Linear
    let norm: LayerNorm

    nonisolated override init() { fatalError("Use init(dim:)") }

    init(dim: Int) {
        self.linear = Linear(dim, dim * 6)
        self.norm = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, emb: MLXArray) -> (MLXArray, MLXArray, MLXArray, MLXArray, MLXArray) {
        let embProcessed = linear(silu(emb))
        let parts = embProcessed.split(parts: 6, axis: 1)
        
        let shiftMsa = parts[0].expandedDimensions(axis: 1)
        let scaleMsa = parts[1].expandedDimensions(axis: 1)
        let gateMsa = parts[2].expandedDimensions(axis: 1)
        let shiftMlp = parts[3].expandedDimensions(axis: 1)
        let scaleMlp = parts[4].expandedDimensions(axis: 1)
        let gateMlp = parts[5].expandedDimensions(axis: 1)

        let normX = norm(x)
        let modulatedX = normX * (MLXArray(1) + scaleMsa) + shiftMsa
        return (modulatedX, gateMsa, shiftMlp, scaleMlp, gateMlp)
    }
}

final class DiT: Module {
    let dim: Int
    let heads: Int
    let depth: Int

    let input_embed: Linear
    let time_embed: TimestepEmbedding
    let blocks: [DiTBlock]
    let final_norm: AdaLayerNormZero_Final
    let final_linear: Linear

    nonisolated override init() { fatalError("Use init(dim:heads:depth:)") }

    init(dim: Int, heads: Int, depth: Int, textDim: Int = 512) {
        self.dim = dim
        self.heads = heads
        self.depth = depth
        
        self.input_embed = Linear(80, dim)
        self.time_embed = TimestepEmbedding(dim: dim)
        
        self.blocks = (0..<depth).map { _ in
            DiTBlock(dim: dim, heads: heads, dimHead: dim / heads)
        }
        
        self.final_norm = AdaLayerNormZero_Final(dim: dim)
        self.final_linear = Linear(dim, 80)
        super.init()
    }
    
    func callAsFunction(x: MLXArray, t: MLXArray, cond: MLXArray? = nil) -> MLXArray {
        var h = input_embed(x)
        let t_emb = time_embed(t)
        
        for block in blocks {
            h = block(h, t: t_emb)
        }
        
        h = final_norm(h, emb: t_emb)
        return final_linear(h)
    }
}

// swiftlint:disable:next type_name
final class AdaLayerNormZero_Final: Module {
    let silu: SiLU = SiLU()
    let linear: Linear
    let norm: LayerNorm

    nonisolated override init() { fatalError("Use init(dim:)") }

    init(dim: Int) {
        self.linear = Linear(dim, dim * 2)
        self.norm = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, emb: MLXArray) -> MLXArray {
        let embProcessed = linear(silu(emb))
        let parts = embProcessed.split(parts: 2, axis: 1)
        let scale = parts[0].expandedDimensions(axis: 1)
        let shift = parts[1].expandedDimensions(axis: 1)
        return norm(x) * (MLXArray(1) + scale) + shift
    }
}

final class TimestepEmbedding: Module {
    let time_embed: SinusPositionEmbedding
    let time_mlp: Sequential

    nonisolated override init() { fatalError("Use init(dim:)") }

    init(dim: Int) {
        self.time_embed = SinusPositionEmbedding(dim: 256)
        self.time_mlp = Sequential(layers: [
            Linear(256, dim),
            SiLU(),
            Linear(dim, dim)
        ])
        super.init()
    }

    func callAsFunction(_ t: MLXArray) -> MLXArray {
        return time_mlp(time_embed(t))
    }
}

final class DiTBlock: Module {
    let norm1: AdaLayerNormZero
    let norm2: LayerNorm
    let attn: Attention
    let ff: Sequential

    nonisolated override init() { fatalError("Use init(dim:heads:dimHead:)") }

    init(dim: Int, heads: Int, dimHead: Int) {
        self.norm1 = AdaLayerNormZero(dim: dim)
        self.norm2 = LayerNorm(dimensions: dim, eps: 1e-6, affine: false)
        self.attn = Attention(dim: dim, heads: heads, dimHead: dimHead)
        self.ff = Sequential(layers: [
            Linear(dim, dim * 4),
            GELU(),
            Linear(dim * 4, dim)
        ])
        super.init()
    }

    func callAsFunction(_ x: MLXArray, t: MLXArray) -> MLXArray {
        let (normX, gateMsa, shiftMlp, scaleMlp, gateMlp) = norm1(x, emb: t)
        let attnOut = attn(normX)
        var out = x + gateMsa * attnOut
        
        let normedFf = norm2(out) * (MLXArray(1) + scaleMlp) + shiftMlp
        out = out + gateMlp * ff(normedFf)
        return out
    }
}

final class Attention: Module {
    let heads: Int
    let scale: Float
    let to_qkv: Linear
    let to_out: Linear

    nonisolated override init() { fatalError("Use init(dim:heads:dimHead:)") }

    init(dim: Int, heads: Int, dimHead: Int) {
        self.heads = heads
        self.scale = 1.0 / sqrt(Float(dimHead))
        self.to_qkv = Linear(dim, dim * 3)
        self.to_out = Linear(dim, dim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let B = x.shape[0]
        let L = x.shape[1]
        let qkv = to_qkv(x).split(parts: 3, axis: -1)
        let (q, k, v) = (qkv[0], qkv[1], qkv[2])
        
        let q_heads = q.reshaped([B, L, heads, -1]).transposed(axes: [0, 2, 1, 3])
        let k_heads = k.reshaped([B, L, heads, -1]).transposed(axes: [0, 2, 1, 3])
        let v_heads = v.reshaped([B, L, heads, -1]).transposed(axes: [0, 2, 1, 3])
        
        let out = MLXFast.scaledDotProductAttention(queries: q_heads, keys: k_heads, values: v_heads, scale: scale, mask: nil)
        return to_out(out.transposed(axes: [0, 2, 1, 3]).reshaped([B, L, -1]))
    }
}
