import AVFoundation
import Foundation
import MLX
import MLXNN
import Tokenizers

enum F5Error: Error {
    case audioLoadFailed
    case audioConversionFailed
}

public final class F5TTS: @unchecked Sendable {
    let transformer: DiT
    let vocoder: Vocos
    let tokenizer: Tokenizer

    init(transformer: DiT, vocoder: Vocos, tokenizer: Tokenizer) {
        self.transformer = transformer
        self.vocoder = vocoder
        self.tokenizer = tokenizer
    }

    public static func load(modelPath: String, vocabPath: String, vocoderPath: String) throws -> F5TTS {

        // ── Step 1: Load DiT weights as fp16 ─────────────────────────────────
        // loadFloat16Weights() memory-maps the file and converts one tensor at
        // a time — peak RAM = accumulated fp16 + largest single fp32 tensor
        // (~700 MB total) instead of 3× the file size with the naive approach.
        print("[F5-TTS/load] Step 1: streaming fp16 load from \(URL(fileURLWithPath: modelPath).lastPathComponent)…")
        let f16Transformer: [String: MLXArray]
        do {
            f16Transformer = try loadFloat16Weights(url: URL(fileURLWithPath: modelPath))
            print("[F5-TTS/load] Step 1a: loaded \(f16Transformer.count) tensors (fp16)")
        } catch {
            print("[F5-TTS/load] Step 1a FAILED: \(error)")
            throw error
        }

        let transformer = DiT(dim: 1024, heads: 16, depth: 22)
        do {
            try transformer.update(parameters: ModuleParameters.unflattened(f16Transformer))
            print("[F5-TTS/load] Step 1b: DiT parameters updated")
        } catch {
            let sampleKeys = Array(f16Transformer.keys.sorted().prefix(10))
            print("[F5-TTS/load] Step 1b FAILED: \(error)")
            print("[F5-TTS/load]   First 10 weight keys: \(sampleKeys)")
            throw error
        }

        // ── Step 2: Load Vocos weights as fp16 ───────────────────────────────
        print("[F5-TTS/load] Step 2: streaming fp16 load from \(URL(fileURLWithPath: vocoderPath).lastPathComponent)…")
        let f16Vocoder: [String: MLXArray]
        do {
            f16Vocoder = try loadFloat16Weights(url: URL(fileURLWithPath: vocoderPath))
            print("[F5-TTS/load] Step 2a: loaded \(f16Vocoder.count) vocoder tensors (fp16)")
        } catch {
            print("[F5-TTS/load] Step 2a FAILED: \(error)")
            throw error
        }

        let vocoder = Vocos(
            inputChannels: 80, dim: 512, intermediateDim: 1536,
            numLayers: 8, nFFT: 1024, hopLength: 256
        )
        do {
            try vocoder.update(parameters: ModuleParameters.unflattened(f16Vocoder))
            print("[F5-TTS/load] Step 2b: Vocos parameters updated (\(f16Vocoder.count) tensors)")
        } catch {
            let sampleKeys = Array(f16Vocoder.keys.sorted().prefix(10))
            print("[F5-TTS/load] Step 2b FAILED: \(error)")
            print("[F5-TTS/load]   First 10 vocoder keys: \(sampleKeys)")
            throw error
        }

        // ── Step 3: Build tokenizer ───────────────────────────────────────────
        print("[F5-TTS/load] Step 3: reading vocab from \(URL(fileURLWithPath: vocabPath).lastPathComponent)…")
        let vocabText: String
        do {
            vocabText = try String(contentsOfFile: vocabPath, encoding: .utf8)
        } catch {
            print("[F5-TTS/load] Step 3 FAILED (read vocab): \(error)")
            throw error
        }
        var vocab: [String: Int] = [:]
        for (index, line) in vocabText.components(separatedBy: .newlines).enumerated() {
            if !line.isEmpty { vocab[line] = index }
        }
        print("[F5-TTS/load] Step 3: vocab size = \(vocab.count) tokens")
        let tokenizer = Tokenizer(vocab: vocab)

        print("[F5-TTS/load] ── load complete")
        return F5TTS(transformer: transformer, vocoder: vocoder, tokenizer: tokenizer)
    }

    // MARK: - Inference

    public func generate(
        text: String,
        referenceAudioURL: URL,
        referenceText: String,
        steps: Int = 32
    ) async throws -> [Float] {
        print("[InternalF5] generate() — \(text.count) chars, \(steps) steps")

        // 1. Load reference audio resampled to 24 kHz
        //    Hard-cap at 3 seconds: attention is O(n²) over ref+target frames.
        //    3s → ~281 frames keeps the total sequence manageable on device.
        let maxRefSamples = 3 * 24000
        var refSamples = try loadAudio(url: referenceAudioURL, targetSampleRate: 24000)
        if refSamples.count > maxRefSamples { refSamples = Array(refSamples.prefix(maxRefSamples)) }
        let refDuration = Double(refSamples.count) / 24000.0
        print("[InternalF5] Reference: \(refSamples.count) samples (\(String(format: "%.1f", refDuration))s, capped)")

        // 2. Compute reference mel spectrogram [80, refFrames]
        let filterbank = makeMelFilterbank(sampleRate: 24000, nFFT: 1024, nMels: 80)
        let melFeatures = MelSpectrogramFeatures(
            sampleRate: 24000, nFFT: 1024, hopLength: 256, nMels: 80, filterbank: filterbank)
        let refMel = melFeatures(x: MLXArray(refSamples))  // [80, refFrames]
        let refFrames = refMel.shape[1]

        // Reshape to [1, refFrames, 80] in fp16 — keeps the ODE loop in fp16 throughout
        let refMelBatch = refMel.transposed().expandedDimensions(axis: 0).asType(.float16)
        print("[InternalF5] Reference mel: \(refFrames) frames")

        // 3. Target length: ~3 frames/char at 93.75 fps, hard-capped at 200 frames (~2.1s).
        //    Total sequence ≤ ~480 frames keeps attention feasible on device.
        let targetFrames = min(200, max(40, text.count * 3))
        print("[InternalF5] Target: \(targetFrames) frames (~\(String(format: "%.1f", Double(targetFrames) / 93.75))s)")

        // 4. Flow-matching ODE: Euler from t=0 (noise) → t=1 (data)
        //    Reference portion stays fixed; only the target portion diffuses.
        var targetXt = MLXRandom.normal([1, targetFrames, 80]).asType(.float16)
        let dt = Float(1.0) / Float(steps)
        print("[InternalF5] Starting ODE (\(steps) steps, total seq = \(refFrames + targetFrames) frames)…")

        for i in 0..<steps {
            let tVal = Float(i) * dt                        // 0 … (steps-1)/steps
            let tArr = MLXArray([tVal])                     // [1] — batch dim for time embed

            // Full-sequence input: [1, refFrames + targetFrames, 80]
            let xt = MLX.concatenated([refMelBatch, targetXt], axis: 1)
            let velocity = transformer(x: xt, t: tArr)     // [1, refFrames + targetFrames, 80]

            // Extract velocity for the target portion only
            // velocity[0] → [totalFrames, 80]; [refFrames...] → [targetFrames, 80]
            let targetVel = velocity[0][refFrames...].expandedDimensions(axis: 0)  // [1, target, 80]
            targetXt = targetXt + targetVel * dt

            // Force MLX to materialise this step before building the next graph node.
            // Without eval() every step the lazy graph grows to ~steps × model_size,
            // which exhausts RAM and freezes the device.
            MLX.eval(targetXt)
            if i % 4 == 0 || i == steps - 1 {
                print("[InternalF5] ODE step \(i + 1)/\(steps)")
            }
        }
        print("[InternalF5] ODE done — decoding through Vocos")

        // 5. Decode generated mel through Vocos → waveform
        let audio = vocoder.decode(targetXt)
        MLX.eval(audio)

        let samples = audio.reshaped([-1]).asType(.float32).asArray(Float.self)
        print("[InternalF5] Output: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / 24000.0))s)")
        return samples
    }

    // MARK: - Audio helpers

    private func loadAudio(url: URL, targetSampleRate: Double = 24000) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let srcFormat = audioFile.processingFormat

        // Validate before touching AVAudioPCMBuffer — a zero sampleRate/channelCount
        // causes an NSException that Swift try-catch cannot intercept.
        guard srcFormat.sampleRate > 0, srcFormat.channelCount > 0 else {
            throw F5Error.audioLoadFailed
        }
        let fileFrames = audioFile.length
        guard fileFrames > 0 else { throw F5Error.audioLoadFailed }

        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else { throw F5Error.audioLoadFailed }

        guard let srcBuf = AVAudioPCMBuffer(
            pcmFormat: srcFormat,
            frameCapacity: AVAudioFrameCount(fileFrames)
        ) else { throw F5Error.audioLoadFailed }
        try audioFile.read(into: srcBuf)

        // Fast path: already in the right format
        if abs(srcFormat.sampleRate - targetSampleRate) < 1,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32,
           let ch = srcBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(srcBuf.frameLength)))
        }

        let durSecs = Double(srcBuf.frameLength) / srcFormat.sampleRate
        let dstFrames = AVAudioFrameCount(ceil(durSecs * targetSampleRate))
        guard dstFrames > 0,
              let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrames),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { throw F5Error.audioLoadFailed }

        var used = false
        var convErr: NSError?
        converter.convert(to: dstBuf, error: &convErr) { _, status in
            if !used { used = true; status.pointee = .haveData; return srcBuf }
            status.pointee = .endOfStream; return nil
        }
        if let e = convErr { throw e }

        let n = Int(dstBuf.frameLength)
        guard n > 0, let ch = dstBuf.floatChannelData else { throw F5Error.audioLoadFailed }
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }

    /// Standard triangular mel filterbank  [nMels, nFFT/2+1]
    private func makeMelFilterbank(sampleRate: Int, nFFT: Int, nMels: Int,
                                   fMin: Float = 0, fMax: Float? = nil) -> MLXArray {
        let fMaxHz = fMax ?? Float(sampleRate) / 2.0
        func hzToMel(_ hz: Float) -> Float { 2595.0 * log10(1.0 + hz / 700.0) }
        func melToHz(_ mel: Float) -> Float { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMaxHz)
        let fftBins = nFFT / 2 + 1

        let melPts = (0..<(nMels + 2)).map { i -> Float in
            melMin + Float(i) * (melMax - melMin) / Float(nMels + 1)
        }
        let freqPts = melPts.map { melToHz($0) }
        let binFreqs = (0..<fftBins).map { Float($0) * Float(sampleRate) / Float(nFFT) }

        var fb = [Float](repeating: 0.0, count: nMels * fftBins)
        for m in 0..<nMels {
            let fL = freqPts[m], fC = freqPts[m + 1], fH = freqPts[m + 2]
            for k in 0..<fftBins {
                let f = binFreqs[k]
                if f >= fL && f <= fC {
                    fb[m * fftBins + k] = (f - fL) / (fC - fL)
                } else if f > fC && f <= fH {
                    fb[m * fftBins + k] = (fH - f) / (fH - fC)
                }
            }
        }
        return MLXArray(fb).reshaped([nMels, fftBins])
    }

    // MARK: - Streaming fp16 safetensors loader

    /// Reads a .safetensors file via mmap and converts each F32 tensor to
    /// Float16 before moving on to the next one.
    ///
    /// Peak RAM = (accumulated fp16 tensors) + (one fp32 tensor at a time).
    /// For the 1.3 GB DiT this stays well under 800 MB, versus the naive
    /// loadArrays → mapValues → eval path which needs ~3× the file size.
    private static func loadFloat16Weights(url: URL) throws -> [String: MLXArray] {
        // Memory-map: the OS pages in only the bytes we actually read.
        let file = try Data(contentsOf: url, options: .mappedIfSafe)
        guard file.count >= 8 else { throw F5Error.audioLoadFailed }

        // First 8 bytes = header length (little-endian uint64)
        let headerLen = file.withUnsafeBytes { buf -> Int in
            var n: UInt64 = 0
            withUnsafeMutableBytes(of: &n) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: buf[0..<8]))
            }
            return Int(n.littleEndian)
        }
        let dataStart = 8 + headerLen
        guard file.count >= dataStart else { throw F5Error.audioLoadFailed }

        guard let header = try JSONSerialization.jsonObject(
            with: file.subdata(in: 8..<dataStart)
        ) as? [String: Any] else { throw F5Error.audioLoadFailed }

        var out: [String: MLXArray] = [:]
        out.reserveCapacity(header.count)

        for (name, info) in header {
            guard name != "__metadata__",
                  let d    = info as? [String: Any],
                  let dtype = d["dtype"] as? String
            else { continue }

            // Shape: JSON integers arrive as NSNumber via JSONSerialization
            let shape: [Int] = (d["shape"] as? [Any] ?? []).compactMap {
                ($0 as? NSNumber)?.intValue ?? $0 as? Int
            }

            // data_offsets: [start, end] relative to the data section
            guard let rawOff = d["data_offsets"] as? [Any], rawOff.count == 2,
                  let o0 = (rawOff[0] as? NSNumber)?.intValue ?? rawOff[0] as? Int,
                  let o1 = (rawOff[1] as? NSNumber)?.intValue ?? rawOff[1] as? Int
            else { continue }

            let byteStart = dataStart + o0
            let byteEnd   = dataStart + o1
            guard byteEnd <= file.count, byteEnd > byteStart else { continue }

            let dims = shape.isEmpty ? [1] : shape

            switch dtype {
            case "F32":
                let count = (byteEnd - byteStart) / 4
                guard !isEmpty else { continue }
                // withUnsafeBytes keeps the pointer valid for this closure only.
                // eval() is called INSIDE so MLX materialises the fp16 tensor
                // before the pointer expires, then the fp32 source can be freed.
                let arr = file.subdata(in: byteStart..<byteEnd).withUnsafeBytes { raw -> MLXArray in
                    let fp32 = Array(UnsafeBufferPointer(
                        start: raw.bindMemory(to: Float.self).baseAddress!,
                        count: count))
                    let a = MLXArray(fp32).reshaped(dims).asType(.float16)
                    MLX.eval(a)
                    return a
                }
                out[name] = arr

            case "F16":
                let count = (byteEnd - byteStart) / 2
                guard !isEmpty else { continue }
                let arr = file.subdata(in: byteStart..<byteEnd).withUnsafeBytes { raw -> MLXArray in
                    let u16 = raw.bindMemory(to: UInt16.self)
                    let fp32 = (0..<count).map { Float(Float16(bitPattern: u16[$0])) }
                    let a = MLXArray(fp32).reshaped(dims).asType(.float16)
                    MLX.eval(a)
                    return a
                }
                out[name] = arr

            case "BF16":
                let count = (byteEnd - byteStart) / 2
                guard !isEmpty else { continue }
                let arr = file.subdata(in: byteStart..<byteEnd).withUnsafeBytes { raw -> MLXArray in
                    let u16 = raw.bindMemory(to: UInt16.self)
                    let fp32 = (0..<count).map { i -> Float in
                        Float(bitPattern: UInt32(u16[i]) << 16)
                    }
                    let a = MLXArray(fp32).reshaped(dims).asType(.float16)
                    MLX.eval(a)
                    return a
                }
                out[name] = arr

            default:
                continue  // I8, I32, etc. — not expected in F5-TTS weights
            }
        }

        print("[F5-TTS/loader] \(out.count) tensors loaded as fp16 from \(url.lastPathComponent)")
        return out
    }
}

// Minimal character-level tokenizer
public struct Tokenizer {
    let vocab: [String: Int]
    func encode(text: String) -> [Int] {
        return text.map { vocab[String($0)] ?? 0 }
    }
}
