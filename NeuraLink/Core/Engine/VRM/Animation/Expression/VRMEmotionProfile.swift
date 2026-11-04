//
//  VRMEmotionProfile.swift
//  NeuraLink
//
//  Maps AI emotion tag names to multi-blend VRMExpressionPreset weight profiles.
//  Blended weights produce more natural, nuanced facial expressions.
//
//  Created by Dedicatus on 03/05/2026.
//

import Foundation

// MARK: - Preset Lists

/// Mood-driven expression presets that the emotion system lerps every frame.
let vrmMoodPresets: [VRMExpressionPreset] = [
    .happy, .angry, .sad, .relaxed, .surprised, .neutral
]

/// Blink-driven presets managed by the emotion system (for wink support).
let vrmBlinkEmotionPresets: [VRMExpressionPreset] = [.blinkLeft, .blinkRight]

// MARK: - VRMEmotionProfile

/// A named emotion expressed as a weighted blend of multiple VRM presets.
struct VRMEmotionProfile {

    // MARK: - Properties

    let weights: [VRMExpressionPreset: Float]

    /// Whether this profile requires controlling blink presets directly (e.g. wink).
    let controlsBlink: Bool

    init(weights: [VRMExpressionPreset: Float], controlsBlink: Bool = false) {
        self.weights = weights
        self.controlsBlink = controlsBlink
    }

    /// Target weight for a given preset (0 if not in this profile).
    func weight(for preset: VRMExpressionPreset) -> Float {
        weights[preset] ?? 0
    }

    // MARK: - Named Profiles

    /// Soft happy — slightly relaxed to avoid an oversized grin.
    static let happy = VRMEmotionProfile(weights: [.happy: 0.6, .relaxed: 0.2])

    /// Anger with a touch of surprise for intensity.
    static let angry = VRMEmotionProfile(weights: [.angry: 1.0])

    /// Sadness.
    static let sad = VRMEmotionProfile(weights: [.sad: 1.0])

    /// Calm and content.
    static let relaxed = VRMEmotionProfile(weights: [.relaxed: 1.0])

    /// Wide-eyed surprise.
    static let surprised = VRMEmotionProfile(weights: [.surprised: 1.0])

    /// Shocked — surprise pushed harder.
    static let shocked = VRMEmotionProfile(weights: [.surprised: 0.9, .angry: 0.1])

    /// Shy — soft sadness + slight relaxation (bashful, eyes down).
    static let shy = VRMEmotionProfile(weights: [.sad: 0.3, .relaxed: 0.4, .happy: 0.1])

    /// Embarrassed — flustered mix of sad, surprised, and a hint of happy.
    static let embarrassed = VRMEmotionProfile(weights: [.sad: 0.4, .surprised: 0.3, .happy: 0.1])

    /// Bored — droopy, low-energy; mostly sad with a touch of relaxed.
    static let bored = VRMEmotionProfile(weights: [.sad: 0.3, .relaxed: 0.5])

    /// Confused — puzzled; light surprise with mild sadness.
    static let confused = VRMEmotionProfile(weights: [.surprised: 0.4, .sad: 0.2])

    /// Wink — closes only the left eye; disables the auto-blink controller.
    static let wink = VRMEmotionProfile(
        weights: [.blinkLeft: 1.0, .blinkRight: 0.0],
        controlsBlink: true
    )

    /// Neutral — all presets zeroed.
    static let neutral = VRMEmotionProfile(weights: [:])

    // MARK: - Lookup

    static func forName(_ name: String) -> VRMEmotionProfile {
        switch name.lowercased() {
        case "happy":       return .happy
        case "angry":       return .angry
        case "sad":         return .sad
        case "relaxed":     return .relaxed
        case "surprised":   return .surprised
        case "shocked":     return .shocked
        case "shy":         return .shy
        case "embarrassed": return .embarrassed
        case "bored":       return .bored
        case "confused":    return .confused
        case "wink":        return .wink
        default:            return .neutral
        }
    }
}
