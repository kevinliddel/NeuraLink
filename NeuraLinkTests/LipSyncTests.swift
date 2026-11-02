//
//  LipSyncTests.swift
//  NeuraLinkTests
//
//  The mouth cue: band energies name the vowel, the level follows the
//  recent loudest and silence closes the mouth, a stale cue reads as
//  silence, and the controller takes the analysed shape and holds it.
//  See docs/LipSync.md.
//
//  Created by Dedicatus on 02/11/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Lip sync")
struct LipSyncTests {
    private static let rate = 48_000.0

    /// 0.1 s of the given partials.
    private static func tone(_ partials: [(hz: Double, amplitude: Float)]) -> [Float] {
        let count = Int(rate * 0.1)
        return (0..<count).map { index in
            let t = Double(index) / rate
            return partials.reduce(0) { $0 + $1.amplitude * Float(sin(2 * .pi * $1.hz * t)) }
        }
    }

    private static func cue(
        _ samples: [Float], analyzer: LipSyncAudioAnalyzer = LipSyncAudioAnalyzer(), at time: TimeInterval = 10
    ) -> LipSyncAudioAnalyzer.Result {
        samples.withUnsafeBufferPointer { analyzer.analyze($0, sampleRate: rate, at: time) }
    }

    @Test("Band energies name the vowel")
    func vowels() {
        #expect(Self.cue(Self.tone([(800, 1), (1_200, 1)])).sample.vowel == .aa)
        #expect(Self.cue(Self.tone([(300, 0.5), (2_300, 1)])).sample.vowel == .ih)
        #expect(Self.cue(Self.tone([(300, 0.5), (1_000, 0.7), (2_300, 1)])).sample.vowel == .ee)
        #expect(Self.cue(Self.tone([(300, 1), (800, 0.3)])).sample.vowel == .ou)
        #expect(Self.cue(Self.tone([(500, 1), (900, 0.6)])).sample.vowel == .oh)
        #expect(LipSyncAudioAnalyzer.vowel(low: 0, mid: 0, high: 0) == nil)
    }

    @Test("The level follows the recent loudest; silence closes the mouth")
    func level() {
        let analyzer = LipSyncAudioAnalyzer()
        let loud = Self.cue(Self.tone([(300, 0.5)]), analyzer: analyzer, at: 10)
        #expect(loud.sample.level == 1)
        #expect(abs(loud.rms - 0.5 / Float(2).squareRoot()) < 0.01)
        let quiet = Self.cue(Self.tone([(300, 0.1)]), analyzer: analyzer, at: 10.1)
        #expect(quiet.sample.level > 0.15 && quiet.sample.level < 0.3)
        let silence = Self.cue([Float](repeating: 0, count: 4_800), analyzer: analyzer, at: 10.2)
        #expect(silence.sample.level == 0)
        #expect(silence.sample.vowel == nil)
    }

    @Test("A stale cue reads as silence")
    func feed() {
        let feed = LipSyncFeed()
        #expect(feed.current(at: 5) == nil)
        feed.publish(LipSyncSample(level: 0.8, vowel: .aa, time: 5))
        #expect(feed.current(at: 5.1)?.level == 0.8)
        #expect(feed.current(at: 5 + LipSyncFeed.maxAge + 0.01) == nil)
        feed.reset()
        #expect(feed.current(at: 5.1) == nil)
    }

    @MainActor
    @Test("The controller takes the named shape and holds it, and cycles without one")
    func controller() {
        let controller = VRMLipSyncController()
        controller.update(audioLevel: 0.5, vowel: .ou, deltaTime: 0.1)
        #expect(controller.activeVowel == .ou)
        controller.update(audioLevel: 0.5, vowel: .ee, deltaTime: 0.01)
        #expect(controller.activeVowel == .ou, "a shape shows for its minimum first")
        controller.update(audioLevel: 0.5, vowel: .ee, deltaTime: 0.07)
        #expect(controller.activeVowel == .ee)
        controller.update(audioLevel: 0.5, vowel: .ee, deltaTime: 0.5)
        #expect(controller.activeVowel == .ee, "held while the analysis agrees")
        controller.update(audioLevel: 0.5, vowel: nil, deltaTime: 0.15)
        #expect(controller.activeVowel == .oh, "no shape named: the cycle moves on")
    }
}
