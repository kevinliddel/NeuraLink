//
//  AcousticAffect.swift
//  NeuraLink
//
//  How the user sounds, not just what they said — Companion Evolution
//  pillar 1 (docs/LLM_VOICE.md). Per-utterance acoustic features are
//  judged against the user's own running baseline, so a naturally quiet
//  voice is not "subdued" and a naturally fast one is not "animated".
//  Framework-free and unit-tested; the signal processing is in
//  Data/Audio/AcousticFeatureExtractor.
//
//  Created by Dedicatus on 16/10/2026.
//

import Foundation

/// What one utterance measured.
struct AcousticFeatures: Equatable, Sendable {
    var durationSec: Double
    /// Mean fundamental frequency over voiced frames; nil when none.
    var pitchMeanHz: Double?
    /// Spread of the fundamental: flat (monotone) vs. lively.
    var pitchStdHz: Double
    /// Mean and spread of per-frame RMS over voiced frames (0…1).
    var energyMean: Double
    var energyStd: Double
    /// Silences of ≥ 150 ms strictly inside the utterance.
    var pauseCount: Int
    /// Words in the transcript, once it arrives.
    var wordCount: Int?

    var wordsPerSecond: Double? {
        guard let wordCount, durationSec > 0 else { return nil }
        return Double(wordCount) / durationSec
    }

    var pausesPerSecond: Double {
        durationSec > 0 ? Double(pauseCount) / durationSec : 0
    }
}

/// The user's usual voice, learned as an exponential moving average.
struct AcousticBaseline: Equatable, Sendable {
    var energyMean: Double = 0
    var pitchMeanHz: Double?
    var wordsPerSecond: Double?
    var samples = 0

    /// Utterances needed before judgements are relative to the baseline.
    static let warmup = 2
    static let alpha = 0.25

    var isReady: Bool { samples >= Self.warmup }

    mutating func absorb(_ features: AcousticFeatures) {
        let weight = samples == 0 ? 1.0 : Self.alpha
        energyMean += (features.energyMean - energyMean) * weight
        if let pitch = features.pitchMeanHz {
            pitchMeanHz = pitchMeanHz.map { $0 + (pitch - $0) * weight } ?? pitch
        }
        if let rate = features.wordsPerSecond {
            wordsPerSecond = wordsPerSecond.map { $0 + (rate - $0) * weight } ?? rate
        }
        samples += 1
    }
}

enum AffectLabel: String, Sendable {
    case neutral, subdued, animated, hesitant
}

/// Speed / intonation / pitch multipliers for the local voices.
struct TTSModulation: Equatable, Sendable {
    var speed: Double = 1
    var intonation: Double = 1
    var pitch: Double = 1

    static let none = TTSModulation()
}

enum AcousticAffect {

    /// Utterances shorter than this say nothing reliable about mood.
    static let minDurationSec = 1.0

    /// Relative to the baseline: quiet and slow and flat → subdued; loud or
    /// lively and quick → animated; slow with many pauses → hesitant.
    static func classify(_ features: AcousticFeatures, baseline: AcousticBaseline) -> AffectLabel {
        guard baseline.isReady, features.durationSec >= minDurationSec, baseline.energyMean > 0 else { return .neutral }
        let energyRatio = features.energyMean / baseline.energyMean
        let rateRatio: Double
        if let rate = features.wordsPerSecond, let usual = baseline.wordsPerSecond, usual > 0 {
            rateRatio = rate / usual
        } else {
            rateRatio = 1
        }
        if energyRatio <= 0.7 && rateRatio <= 0.9 && features.pitchStdHz < 25 { return .subdued }
        if (energyRatio >= 1.3 || features.pitchStdHz >= 60) && rateRatio >= 1.1 { return .animated }
        if features.pausesPerSecond >= 0.4 && rateRatio <= 0.85 { return .hesitant }
        return .neutral
    }

    /// The prompt tag; nil for neutral, which needs no directive.
    static func tag(for label: AffectLabel) -> String? {
        switch label {
        case .neutral:
            return nil
        case .subdued:
            return "[User acoustic affect: subdued — low vocal energy, slower cadence, flat pitch] "
                + "→ Tone directive: speak softly, match their lower energy, be calm and unhurried; "
                + "don't ask what's wrong unless they open that door."
        case .animated:
            return "[User acoustic affect: animated — lively energy, quick cadence] "
                + "→ Tone directive: match their brightness; keep replies quick, warm and playful."
        case .hesitant:
            return "[User acoustic affect: hesitant — frequent pauses, slower cadence] "
                + "→ Tone directive: give them room; shorter replies, gentle prompts, no pressure."
        }
    }

    /// What to send once the user is back to their usual voice.
    static let clearTag = "[User acoustic affect: back to their usual voice] → Tone directive: your normal tone."

    static func modulation(for label: AffectLabel) -> TTSModulation {
        switch label {
        case .neutral: return .none
        case .subdued: return TTSModulation(speed: 0.92, intonation: 0.85, pitch: 0.97)
        case .animated: return TTSModulation(speed: 1.06, intonation: 1.15, pitch: 1.03)
        case .hesitant: return TTSModulation(speed: 0.95, intonation: 0.9, pitch: 1)
        }
    }

    /// Whitespace words, or ~one per four characters for scripts without spaces.
    static func wordCount(of transcript: String) -> Int {
        let words = transcript.split { $0.isWhitespace }
        if words.count == 1, let only = words.first, only.count > 6 { return max(1, (only.count + 3) / 4) }
        return words.count
    }
}
