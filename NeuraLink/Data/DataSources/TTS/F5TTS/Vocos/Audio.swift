import Foundation
import MLX
import MLXNN

func hannWindow(_ n: Int) -> MLXArray {
    let t = MLXArray(0..<n).asType(.float32)
    return 0.5 * (1.0 - MLX.cos(2.0 * Float.pi * t / Float(n - 1)))
}

public final class MelSpectrogramFeatures: Module {
    let sampleRate: Int
    let nFFT: Int
    let hopLength: Int
    let nMels: Int
    let filterbank: MLXArray

    public nonisolated override init() { fatalError("Use designated initializer") }

    public init(sampleRate: Int, nFFT: Int, hopLength: Int, nMels: Int, filterbank: MLXArray) {
        self.sampleRate = sampleRate
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.nMels = nMels
        self.filterbank = filterbank
        super.init()
    }

    public func callAsFunction(x: MLXArray) -> MLXArray {
        let window = hannWindow(nFFT)
        let nSamples = x.shape[0]
        let nFrames = max(1, (nSamples - nFFT) / hopLength + 1)

        var frames: [MLXArray] = []
        for i in 0..<nFrames {
            let start = i * hopLength
            frames.append(x[start..<(start + nFFT)] * window)
        }
        let stacked = MLX.stacked(frames)              // [nFrames, nFFT]
        let spectrum = MLXFFT.rfft(stacked, axis: -1)  // [nFrames, nFFT/2+1] complex
        let magnitudes = spectrum.abs().transposed()   // [nFFT/2+1, nFrames]
        let melSpec = MLX.matmul(filterbank, magnitudes)
        return MLX.log(MLX.maximum(melSpec, MLXArray(1e-5 as Float)))
    }
}

/// ISTFTHead — property names match checkpoint keys: out.* and window
public final class ISTFTHead: Module {
    let nFFT: Int
    let hopLength: Int
    let out: Linear
    var window: MLXArray  // "decoder.window" in checkpoint; initialised to Hann, overwritten by loaded weights

    public nonisolated override init() { fatalError("Use designated initializer") }

    public init(dim: Int, nFFT: Int, hopLength: Int) {
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.out = Linear(dim, nFFT + 2)
        self.window = hannWindow(nFFT)
        super.init()
    }

    public func callAsFunction(input: MLXArray) -> MLXArray {
        // input: [batch, nFrames, dim]
        let x = out(input)                // [batch, nFrames, nFFT + 2]
        let parts = x.split(parts: 2, axis: -1)
        let mag = MLX.exp(parts[0])       // magnitude
        let phase = parts[1]              // phase

        let realPart = mag * MLX.cos(phase)
        let imagPart = mag * MLX.sin(phase)
        let complexSpec = realPart + imagPart.asImaginary()

        // IRFFT: [batch, nFrames, nFFT/2+1] → [batch, nFrames, nFFT]
        let frames = MLXFFT.irfft(complexSpec, n: nFFT, axis: -1)
        let windowed = frames * window    // synthesis windowing

        // Proper overlap-add ISTFT via transposed convolution.
        //
        // MLX.convTransposed1d uses NLC layout: input [N, L, C_in] and
        // weight [C_out, K, C_in]. With:
        //   input  = windowed                                   [batch, nFrames, nFFT]
        //   weight = identity matrix reshaped to                [1,     nFFT,    nFFT]
        //   stride = hopLength
        // the transposed conv computes
        //   y[n, p, 0] = Σ_t windowed[n, t, p − t·hopLength]    (0 ≤ p − t·hopLength < nFFT)
        // which is exactly the overlap-add formula. Output length
        //   outLen = (nFrames − 1)·hopLength + nFFT.
        //
        // Standard ISTFT then divides by Σ_t window²[p − t·hopLength] to
        // invert the synthesis window. We OLA window² the same way and
        // divide, clamping the denominator to avoid edges-of-signal NaNs.
        let nFrames = windowed.shape[1]
        let dtype = windowed.dtype
        let identityKernel = MLXArray
            .eye(nFFT, dtype: dtype)
            .reshaped([1, nFFT, nFFT])

        let signal = MLX.convTransposed1d(
            windowed, identityKernel, stride: hopLength
        ).squeezed(axis: -1)              // [batch, outLen]

        let windowSquared = window * window
        let windowSquaredFrames = MLX.broadcast(
            windowSquared
                .expandedDimensions(axis: 0)
                .expandedDimensions(axis: 0),
            to: [1, nFrames, nFFT]
        )
        let denominator = MLX.convTransposed1d(
            windowSquaredFrames, identityKernel, stride: hopLength
        ).squeezed(axis: -1)              // [1, outLen]

        return signal / MLX.maximum(denominator, MLXArray(1e-8 as Float).asType(dtype))
    }
}
