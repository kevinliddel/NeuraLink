//
//  VRMLipSyncController.swift
//  NeuraLink
//
//  Drives the VRM vowel expressions from a mouth cue: the level opens the
//  mouth, and the shape is the vowel the audio analysis names when it
//  names one, else a cycle weighted toward open vowels, paced like
//  phonemes. Weights move by time-based lerps so the mouth never snaps.
//  See docs/LipSync.md.
//
//  Created by Dedicatus on 17/04/2026.
//

import Foundation

final class VRMLipSyncController {

    // Weighted toward open vowels — mirrors average English phoneme distribution
    private static let vowelSequence: [VRMExpressionPreset] = [
        .aa, .oh, .aa, .ee, .aa, .ih, .oh, .ou, .aa, .ee
    ]

    private static let silenceThreshold: Float = 0.04
    private static let openLerpSpeed: Float = 15.0   // fast open
    private static let closeLerpSpeed: Float = 8.0    // slower close
    /// A shape shows at least this long, cycled or named.
    private static let minVowelDuration: Float = 0.07   // ~70 ms
    private static let maxVowelDuration: Float = 0.14   // ~140 ms

    private var weights: [VRMExpressionPreset: Float] = {
        var w = [VRMExpressionPreset: Float]()
        for v in [VRMExpressionPreset.aa, .ih, .ou, .ee, .oh] { w[v] = 0 }
        return w
    }()

    /// The shape the mouth is forming now.
    private(set) var activeVowel: VRMExpressionPreset = .aa
    private var vowelTimer: Float = 0
    private var vowelDuration: Float = 0.1
    private var sequenceIndex: Int = 0

    // MARK: - Update

    /// `vowel`: the shape the audio analysis names, nil when it names none.
    func update(audioLevel: Float, vowel: LipSyncVowel? = nil, deltaTime: Float) {
        if audioLevel > Self.silenceThreshold {
            advanceVowel(by: deltaTime, hint: vowel, targetAmplitude: audioLevel)
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

    private func advanceVowel(by deltaTime: Float, hint: LipSyncVowel?, targetAmplitude: Float) {
        vowelTimer += deltaTime
        if let hint {
            // The analysis names the shape: take it once the current one has
            // shown for its minimum, and hold it while the analysis agrees.
            let next = Self.preset(for: hint)
            if next != activeVowel, vowelTimer >= Self.minVowelDuration {
                vowelTimer = 0
                activeVowel = next
            }
        } else if vowelTimer >= vowelDuration {
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

    private static func preset(for vowel: LipSyncVowel) -> VRMExpressionPreset {
        switch vowel {
        case .aa: return .aa
        case .ee: return .ee
        case .ih: return .ih
        case .oh: return .oh
        case .ou: return .ou
        }
    }

    private func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }
}
