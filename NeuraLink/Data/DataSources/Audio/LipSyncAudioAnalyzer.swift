//
//  LipSyncAudioAnalyzer.swift
//  NeuraLink
//
//  Mouth cues from PCM: the level, and the vowel the sound's spectrum is
//  nearest. Three bands of a 512-point spectrum, not phonemes: the open
//  vowel (aa) carries its first formant near 800 Hz, the rounded ones (oh,
//  ou) keep their energy under 600 Hz, the front ones (ee, ih) carry a
//  second formant above 1.5 kHz. Rough, and enough for the mouth to follow
//  the words instead of cycling through shapes at random. One instance per
//  audio thread; the level's peak carries between calls.
//  See docs/Engine/LipSync.md.
//
//  Created by Dedicatus on 02/11/2026.
//

import Accelerate
import Foundation

nonisolated final class LipSyncAudioAnalyzer {
    struct Result: Equatable {
        let sample: LipSyncSample
        /// The run's RMS, for callers that compare it with the microphone.
        let rms: Float
    }

    /// Samples per spectrum; a buffer is read in hops of this many.
    static let frameSamples = 512
    private static let bins = frameSamples / 2
    /// Hz. Low: voicing and the rounded vowels; mid: the open vowel's first
    /// formant; high: the front vowels' second formant.
    static let lowBand = 100.0...600.0
    static let midBand = 600.0...1_500.0
    static let highBand = 1_500.0...4_000.0
    /// The band shares that name a shape.
    static let frontShare: Float = 0.45
    static let eeMidShare: Float = 0.2
    static let openShare: Float = 0.35
    static let ohShare: Float = 0.15
    /// Under this level the sound is too faint to name a shape.
    static let voicedLevel: Float = 0.15

    private let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let outReal: UnsafeMutablePointer<Float>
    private let outImaginary: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private var normalizer = LipSyncLevelNormalizer()
    private var lastTime: TimeInterval?

    init() {
        window = .allocate(capacity: Self.frameSamples)
        frame = .allocate(capacity: Self.frameSamples)
        real = .allocate(capacity: Self.bins)
        imaginary = .allocate(capacity: Self.bins)
        outReal = .allocate(capacity: Self.bins)
        outImaginary = .allocate(capacity: Self.bins)
        power = .allocate(capacity: Self.bins)
        vDSP_hann_window(window, vDSP_Length(Self.frameSamples), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        for pointer in [window, frame, real, imaginary, outReal, outImaginary, power] { pointer.deallocate() }
    }

    /// `time`: when the audio was measured (`ProcessInfo.systemUptime`).
    func analyze(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Result {
        guard let base = samples.baseAddress, !samples.isEmpty, let fft else {
            return Result(sample: LipSyncSample(level: 0, vowel: nil, time: time), rms: 0)
        }
        var rms: Float = 0
        vDSP_rmsqv(base, 1, &rms, vDSP_Length(samples.count))
        let elapsed = lastTime.map { time - $0 } ?? 0
        lastTime = time
        let level = normalizer.level(rms: rms, elapsed: elapsed)
        var vowel: LipSyncVowel?
        if level >= Self.voicedLevel {
            let bands = bandPowers(base, count: samples.count, sampleRate: sampleRate, fft: fft)
            vowel = Self.vowel(low: bands.low, mid: bands.mid, high: bands.high)
        }
        return Result(sample: LipSyncSample(level: level, vowel: vowel, time: time), rms: rms)
    }

    /// The shape three band powers are nearest, nil when there is no power.
    static func vowel(low: Float, mid: Float, high: Float) -> LipSyncVowel? {
        let total = low + mid + high
        guard total > 0 else { return nil }
        let midShare = mid / total
        if high / total >= frontShare { return midShare >= eeMidShare ? .ee : .ih }
        if midShare >= openShare { return .aa }
        return midShare >= ohShare ? .oh : .ou
    }

    // MARK: - Spectrum

    /// Band powers summed over every full 512-sample hop of the run (one
    /// zero-padded frame when the run is shorter).
    private func bandPowers(
        _ samples: UnsafePointer<Float>, count: Int, sampleRate: Double, fft: vDSP.FFT<DSPSplitComplex>
    ) -> (low: Float, mid: Float, high: Float) {
        let frameCount = Self.frameSamples
        let binHz = sampleRate / Double(frameCount)
        let low = Self.binRange(Self.lowBand, binHz: binHz)
        let mid = Self.binRange(Self.midBand, binHz: binHz)
        let high = Self.binRange(Self.highBand, binHz: binHz)
        var sums: (low: Float, mid: Float, high: Float) = (0, 0, 0)
        var input = DSPSplitComplex(realp: real, imagp: imaginary)
        var output = DSPSplitComplex(realp: outReal, imagp: outImaginary)
        for hop in 0..<max(1, count / frameCount) {
            let available = min(frameCount, count - hop * frameCount)
            if available < frameCount { vDSP_vclr(frame, 1, vDSP_Length(frameCount)) }
            vDSP_vmul(samples + hop * frameCount, 1, window, 1, frame, 1, vDSP_Length(available))
            frame.withMemoryRebound(to: DSPComplex.self, capacity: Self.bins) {
                vDSP_ctoz($0, 2, &input, 1, vDSP_Length(Self.bins))
            }
            fft.forward(input: input, output: &output)
            vDSP_zvmags(&output, 1, power, 1, vDSP_Length(Self.bins))
            power[0] = 0  // DC and Nyquist share bin 0
            sums.low += Self.sum(power, over: low)
            sums.mid += Self.sum(power, over: mid)
            sums.high += Self.sum(power, over: high)
        }
        return sums
    }

    private static func binRange(_ band: ClosedRange<Double>, binHz: Double) -> Range<Int> {
        let lower = max(1, Int((band.lowerBound / binHz).rounded(.up)))
        let upper = min(bins - 1, Int((band.upperBound / binHz).rounded(.down)))
        return lower..<max(lower, upper + 1)
    }

    private static func sum(_ power: UnsafePointer<Float>, over range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var total: Float = 0
        vDSP_sve(power + range.lowerBound, 1, &total, vDSP_Length(range.count))
        return total
    }
}
