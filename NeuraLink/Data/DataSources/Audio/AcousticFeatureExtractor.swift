//
//  AcousticFeatureExtractor.swift
//  NeuraLink
//
//  Per-utterance acoustic features for AcousticAffect (docs/LLM_VOICE.md):
//  frame RMS, a lag-domain autocorrelation pitch estimate on voiced frames,
//  and inner pauses. Runs once per utterance on a few seconds of mono
//  audio; the input is decimated to ≤ 16 kHz first so the pitch search
//  stays a few million multiplies. Pure: same samples, same features.
//
//  Created by Dedicatus on 16/10/2026.
//

import Accelerate
import Foundation

enum AcousticFeatureExtractor {

    static let frameSec = 0.025
    static let minPitchHz = 70.0
    static let maxPitchHz = 400.0
    /// Normalised autocorrelation peak needed to call a frame voiced.
    static let voicingThreshold: Float = 0.5
    /// How close to the best peak a shorter-lag peak must be to win.
    static let octaveTolerance: Float = 0.9
    /// A frame counts as speech above this share of the loud frames' RMS.
    static let energyFloorRatio: Float = 0.3
    static let pauseSec = 0.15
    static let targetSampleRate = 16_000.0

    static func extract(samples input: [Float], sampleRate inputRate: Double, wordCount: Int? = nil) -> AcousticFeatures {
        let (samples, sampleRate) = decimate(input, from: inputRate)
        let frameLength = max(1, Int(sampleRate * frameSec))
        let duration = Double(input.count) / inputRate
        guard samples.count >= frameLength else {
            return AcousticFeatures(
                durationSec: duration, pitchMeanHz: nil, pitchStdHz: 0, energyMean: 0, energyStd: 0,
                pauseCount: 0, wordCount: wordCount)
        }

        // Frame RMS.
        let frameCount = samples.count / frameLength
        var rms = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<frameCount {
                vDSP_rmsqv(buffer.baseAddress! + index * frameLength, 1, &rms[index], vDSP_Length(frameLength))
            }
        }
        let loud = rms.sorted()[Int(Double(frameCount - 1) * 0.9)]
        let floor = max(0.005, loud * energyFloorRatio)
        let speech = rms.map { $0 >= floor }

        // Energy over speech frames.
        let speechRMS = zip(rms, speech).filter(\.1).map { Double($0.0) }
        let energyMean = speechRMS.isEmpty ? 0 : speechRMS.reduce(0, +) / Double(speechRMS.count)
        let energyStd = standardDeviation(speechRMS, mean: energyMean)

        // Pitch on speech frames.
        let minLag = Int(sampleRate / maxPitchHz)
        let maxLag = min(frameLength - 1, Int(sampleRate / minPitchHz))
        var pitches: [Double] = []
        if maxLag > minLag {
            samples.withUnsafeBufferPointer { buffer in
                for index in 0..<frameCount where speech[index] {
                    let frame = buffer.baseAddress! + index * frameLength
                    if let f0 = pitch(of: frame, length: frameLength, minLag: minLag, maxLag: maxLag, sampleRate: sampleRate) {
                        pitches.append(f0)
                    }
                }
            }
        }
        let pitchMean = pitches.isEmpty ? nil : pitches.reduce(0, +) / Double(pitches.count)
        let pitchStd = pitchMean.map { standardDeviation(pitches, mean: $0) } ?? 0

        return AcousticFeatures(
            durationSec: duration, pitchMeanHz: pitchMean, pitchStdHz: pitchStd, energyMean: energyMean,
            energyStd: energyStd, pauseCount: innerPauses(speech, frameSec: Double(frameLength) / sampleRate),
            wordCount: wordCount)
    }

    /// Silences of at least `pauseSec` between the first and last speech frame.
    static func innerPauses(_ speech: [Bool], frameSec: Double) -> Int {
        guard let first = speech.firstIndex(of: true), let last = speech.lastIndex(of: true), last > first else { return 0 }
        let needed = max(1, Int((pauseSec / frameSec).rounded(.up)))
        var pauses = 0
        var run = 0
        for index in first...last {
            if speech[index] {
                if run >= needed { pauses += 1 }
                run = 0
            } else {
                run += 1
            }
        }
        return pauses
    }

    /// Normalised autocorrelation peak search over the pitch lag range.
    private static func pitch(
        of frame: UnsafePointer<Float>, length: Int, minLag: Int, maxLag: Int, sampleRate: Double
    ) -> Double? {
        var energy: Float = 0
        vDSP_dotpr(frame, 1, frame, 1, &energy, vDSP_Length(length))
        guard energy > 0 else { return nil }
        var scores = [Float](repeating: 0, count: maxLag - minLag + 1)
        for lag in minLag...maxLag {
            var value: Float = 0
            vDSP_dotpr(frame, 1, frame + lag, 1, &value, vDSP_Length(length - lag))
            scores[lag - minLag] = value / energy * Float(length) / Float(length - lag)
        }
        guard let best = scores.max(), best >= voicingThreshold else { return nil }
        // A periodic signal peaks at every multiple of its period, and the
        // lag correction favours the longer ones: take the SHORTEST lag
        // that is a local peak close to the best, which is the fundamental.
        let floor = best * octaveTolerance
        for index in scores.indices where scores[index] >= floor {
            let before = index > 0 ? scores[index - 1] : -1
            let after = index + 1 < scores.count ? scores[index + 1] : -1
            if scores[index] >= before && scores[index] >= after {
                return sampleRate / Double(minLag + index)
            }
        }
        return nil
    }

    /// Integer-factor decimation by block averaging down to ≤ 16 kHz.
    static func decimate(_ samples: [Float], from rate: Double) -> ([Float], Double) {
        let factor = max(1, Int((rate / targetSampleRate).rounded(.down)))
        guard factor > 1 else { return (samples, rate) }
        let count = samples.count / factor
        var out = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                var mean: Float = 0
                vDSP_meanv(buffer.baseAddress! + index * factor, 1, &mean, vDSP_Length(factor))
                out[index] = mean
            }
        }
        return (out, rate / Double(factor))
    }

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }
}
