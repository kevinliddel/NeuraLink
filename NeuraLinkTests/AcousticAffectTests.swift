//
//  AcousticAffectTests.swift
//  NeuraLinkTests
//
//  Acoustic affect (docs/LLM_VOICE.md): the feature extractor on synthetic
//  audio, the WAV reader, the baseline-relative classification, and the
//  state that feeds both engines.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Acoustic affect")
struct AcousticAffectTests {

    private func tone(hz: Double, seconds: Double, amplitude: Float, rate: Double = 16_000) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    private func features(
        duration: Double = 3, pitch: Double? = 180, pitchStd: Double = 30, energy: Double = 0.1,
        pauses: Int = 0, words: Int? = 9
    ) -> AcousticFeatures {
        AcousticFeatures(
            durationSec: duration, pitchMeanHz: pitch, pitchStdHz: pitchStd, energyMean: energy, energyStd: 0.02,
            pauseCount: pauses, wordCount: words)
    }

    @Test("The extractor finds the pitch, the energy and the inner pauses of synthetic speech")
    func extractor() {
        let voiced = AcousticFeatureExtractor.extract(samples: tone(hz: 220, seconds: 1, amplitude: 0.3), sampleRate: 16_000)
        #expect(voiced.durationSec == 1)
        #expect(voiced.pitchMeanHz.map { abs($0 - 220) < 8 } == true)
        #expect(voiced.pitchStdHz < 5)
        #expect(abs(voiced.energyMean - 0.212) < 0.03)
        #expect(voiced.pauseCount == 0)

        let gapped = tone(hz: 150, seconds: 0.5, amplitude: 0.3) + [Float](repeating: 0, count: 4_800)
            + tone(hz: 150, seconds: 0.5, amplitude: 0.3)
        let withPause = AcousticFeatureExtractor.extract(samples: gapped, sampleRate: 16_000, wordCount: 4)
        #expect(withPause.pauseCount == 1)
        #expect(withPause.wordsPerSecond.map { abs($0 - 4 / 1.3) < 0.05 } == true)

        // 48 kHz input is decimated to 16 kHz and read the same.
        let fast = AcousticFeatureExtractor.extract(samples: tone(hz: 220, seconds: 1, amplitude: 0.3, rate: 48_000), sampleRate: 48_000)
        #expect(fast.pitchMeanHz.map { abs($0 - 220) < 8 } == true)
        #expect(AcousticFeatureExtractor.extract(samples: [], sampleRate: 16_000).pitchMeanHz == nil)
    }

    @Test("A 16-bit WAV round-trips through the decoder")
    func wav() {
        let samples = tone(hz: 100, seconds: 0.01, amplitude: 0.5)
        let decoded = WAVDecoder.decode(WAVDecoder.encode16(samples: samples, sampleRate: 16_000))
        #expect(decoded?.sampleRate == 16_000)
        #expect(decoded?.samples.count == samples.count)
        #expect(zip(decoded?.samples ?? [], samples).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(WAVDecoder.decode(Data("not a wav".utf8)) == nil)
    }

    @Test("Classification is relative to the user's own baseline")
    func classification() {
        var baseline = AcousticBaseline()
        #expect(AcousticAffect.classify(features(), baseline: baseline) == .neutral)   // nothing to compare with yet
        baseline.absorb(features())
        baseline.absorb(features())
        #expect(baseline.isReady)
        #expect(abs((baseline.wordsPerSecond ?? 0) - 3) < 0.01)

        #expect(AcousticAffect.classify(features(), baseline: baseline) == .neutral)
        #expect(AcousticAffect.classify(features(pitchStd: 10, energy: 0.05, words: 6), baseline: baseline) == .subdued)
        #expect(AcousticAffect.classify(features(pitchStd: 70, energy: 0.16, words: 12), baseline: baseline) == .animated)
        #expect(AcousticAffect.classify(features(pauses: 2, words: 6), baseline: baseline) == .hesitant)
        #expect(AcousticAffect.classify(features(duration: 0.6, energy: 0.02, words: 1), baseline: baseline) == .neutral)

        #expect(AcousticAffect.tag(for: .neutral) == nil)
        #expect(AcousticAffect.tag(for: .subdued)?.contains("speak softly") == true)
        #expect(AcousticAffect.modulation(for: .animated).speed > 1)
        #expect(AcousticAffect.modulation(for: .subdued).intonation < 1)
        #expect(AcousticAffect.wordCount(of: "What's the weather like?") == 4)
        #expect(AcousticAffect.wordCount(of: "今日はどんな一日だった") == 3)
    }

    @Test("The shared state learns the baseline and announces changes once")
    @MainActor
    func stateFlow() {
        let state = AcousticAffectState.shared
        state.reset()
        defer { state.reset() }
        let enabled = AffectSettings.shared.isEnabled
        AffectSettings.shared.isEnabled = true
        defer { AffectSettings.shared.isEnabled = enabled }

        for _ in 0..<2 {
            state.noteUtterance(features())
            #expect(state.noteTranscript("one two three four five six seven eight nine") == .neutral)
        }
        #expect(state.realtimeTagIfChanged() == nil)
        #expect(state.promptBlock().isEmpty)

        state.noteUtterance(features(pitchStd: 10, energy: 0.05))
        #expect(state.noteTranscript("one two three four five six") == .subdued)
        #expect(state.promptBlock().contains("subdued"))
        #expect(state.modulation == AcousticAffect.modulation(for: .subdued))
        #expect(state.realtimeTagIfChanged()?.contains("subdued") == true)
        #expect(state.realtimeTagIfChanged() == nil)   // same read, nothing new to say

        state.noteUtterance(features())
        state.noteTranscript("one two three four five six seven eight nine")
        #expect(state.realtimeTagIfChanged() == AcousticAffect.clearTag)
    }
}
