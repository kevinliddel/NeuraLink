//
//  VRMLipSyncController.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Foundation

/// Drives VRM vowel expressions from a raw audio amplitude signal.
/// Cycles through vowel shapes on a phoneme-paced timer while smoothing
/// all weights with time-based lerp so mouth movement looks organic.
final class VRMLipSyncController {

    // Weighted toward open vowels — mirrors average English phoneme distribution
    private static let vowelSequence: [VRMExpressionPreset] = [
        .aa, .oh, .aa, .ee, .aa, .ih, .oh, .ou, .aa, .ee
    ]

    private static let silenceThreshold: Float = 0.04
    private static let openLerpSpeed: Float = 15.0   // fast open
    private static let closeLerpSpeed: Float = 8.0    // slower close
    private static let minVowelDuration: Float = 0.07   // ~70 ms
    private static let maxVowelDuration: Float = 0.14   // ~140 ms

    private var weights: [VRMExpressionPreset: Float] = {
        var w = [VRMExpressionPreset: Float]()
        for v in [VRMExpressionPreset.aa, .ih, .ou, .ee, .oh] { w[v] = 0 }
        return w
    }()

    private var activeVowel: VRMExpressionPreset = .aa
    private var vowelTimer: Float = 0
    private var vowelDuration: Float = 0.1
    private var sequenceIndex: Int = 0

    // MARK: - Update

    func update(audioLevel: Float, deltaTime: Float) {
        if audioLevel > Self.silenceThreshold {
            advanceVowel(by: deltaTime, targetAmplitude: audioLevel)
        } else {
            closemouth(deltaTime: deltaTime)
        }
    }

    func apply(to controller: VRMExpressionController?) {
        guard let controller else { return }
        for (vowel, weight) in weights {
            controller.setExpressionWeight(vowel, weight: weight)
        }
    }

    // MARK: - Private

    private func advanceVowel(by deltaTime: Float, targetAmplitude: Float) {
        vowelTimer += deltaTime
        if vowelTimer >= vowelDuration {
            vowelTimer = 0
            vowelDuration = Float.random(in: Self.minVowelDuration...Self.maxVowelDuration)
            sequenceIndex = (sequenceIndex + 1) % Self.vowelSequence.count
            activeVowel = Self.vowelSequence[sequenceIndex]
        }

        let target = min(targetAmplitude * 1.6, 1.0)
        let t = min(Self.openLerpSpeed * deltaTime, 1.0)
        for vowel in weights.keys {
            let goal: Float = vowel == activeVowel ? target : 0
            weights[vowel] = lerp(weights[vowel] ?? 0, goal, t: t)
        }
    }

    private func closemouth(deltaTime: Float) {
        let t = min(Self.closeLerpSpeed * deltaTime, 1.0)
        for vowel in weights.keys {
            let w = lerp(weights[vowel] ?? 0, 0, t: t)
            weights[vowel] = w < 0.005 ? 0 : w
        }
    }

    private func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }
}
