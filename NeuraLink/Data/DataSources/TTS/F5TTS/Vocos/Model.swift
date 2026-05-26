import Foundation
import MLX
import MLXNN

public final class GroupableConv1d: Module, UnaryLayer {
    public let weight: MLXArray
    public let bias: MLXArray?
    public let padding: Int
    public let groups: Int
    public let stride: Int

    public nonisolated override init() { fatalError("Use designated initializer") }

    public init(
        inputChannels: Int,
        outputChannels: Int,
        kernelSize: Int,
        stride: Int = 1,
        padding: Int = 0,
        groups: Int = 1,
        bias: Bool = true
    ) {
        let scale = sqrt(1 / Float(inputChannels * kernelSize))
        self.weight = MLXRandom.uniform(
            low: -scale, high: scale, [outputChannels, kernelSize, inputChannels / groups]
        )
        self.bias = bias ? MLXArray.zeros([outputChannels]) : nil
        self.padding = padding
        self.stride = stride
        self.groups = groups
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = MLX.conv1d(x, weight, stride: stride, padding: padding, groups: groups)
        if let bias { y = y + bias }
        return y
    }
}

// Property names must mirror the checkpoint key paths exactly.
// layers.N.dwconv.* | layers.N.norm.* | layers.N.pwconv1.* | layers.N.pwconv2.* | layers.N.layer_scale_parameter
final class ConvNeXtBlock: Module {
    let dwconv: GroupableConv1d
    let norm: LayerNorm
    let pwconv1: Linear
    let act: GELU
    let pwconv2: Linear
    var layer_scale_parameter: MLXArray  // renamed from gamma to match checkpoint key

    nonisolated override init() { fatalError("Use init(dim:intermediateDim:layerScaleInitValue:)") }

    init(dim: Int, intermediateDim: Int, layerScaleInitValue: Float) {
        self.dwconv = GroupableConv1d(
            inputChannels: dim, outputChannels: dim, kernelSize: 7, padding: 3, groups: dim)
        self.norm = LayerNorm(dimensions: dim, eps: 1e-6)
        self.pwconv1 = Linear(dim, intermediateDim)
        self.act = GELU()
        self.pwconv2 = Linear(intermediateDim, dim)
        self.layer_scale_parameter = layerScaleInitValue * MLXArray.ones([dim])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let residual = x
        var out = dwconv(x)
        out = norm(out)
        out = pwconv1(out)
        out = act(out)
        out = pwconv2(out)
        out = layer_scale_parameter * out
        return residual + out
    }
}

/// Vocos vocoder. Property names mirror the flat checkpoint key hierarchy:
///   embed.* | norm.* | layers.N.* | final_layer_norm.* | decoder.*
public final class Vocos: Module {
    var embed: Conv1d
    var norm: LayerNorm
    var layers: [ConvNeXtBlock]
    var final_layer_norm: LayerNorm
    var decoder: ISTFTHead

    public nonisolated override init() { fatalError("Use designated initializer") }

    init(inputChannels: Int, dim: Int, intermediateDim: Int, numLayers: Int,
         nFFT: Int, hopLength: Int) {
        self.embed = Conv1d(inputChannels: inputChannels, outputChannels: dim,
                            kernelSize: 7, padding: 3)
        self.norm = LayerNorm(dimensions: dim, eps: 1e-6)
        let scale = 1.0 / Float(numLayers)
        self.layers = (0..<numLayers).map { _ in
            ConvNeXtBlock(dim: dim, intermediateDim: intermediateDim, layerScaleInitValue: scale)
        }
        self.final_layer_norm = LayerNorm(dimensions: dim, eps: 1e-6)
        self.decoder = ISTFTHead(dim: dim, nFFT: nFFT, hopLength: hopLength)
        super.init()
    }

    public func decode(_ melFeatures: MLXArray) -> MLXArray {
        var x = embed(melFeatures)
        x = norm(x)
        for layer in layers { x = layer(x) }
        x = final_layer_norm(x)
        return decoder(input: x)
    }
}
