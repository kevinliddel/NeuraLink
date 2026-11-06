//
//  VRMMetalState+Mood.swift
//  NeuraLink
//
//  The body side of Inner life (docs/Companion/LIVING_COMPANION.md): the
//  mood the last session left weights which idle plays next and rests on
//  the face while no emotion is active, fading over the first minutes.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation

extension VRMMetalState {

    /// Reads the mood the character carries into this session, once it is
    /// on screen; the fade starts now.
    func carryMood(for character: String) {
        aiState.sessionMood = CompanionInnerLife.shared.bodyMood(character: character)
        aiState.sessionMoodAt = Date()
        if let mood = aiState.sessionMood {
            nlLog("[InnerLife] \(character) carries a \(mood.rawValue) mood", level: .info)
        }
    }

    /// The idle to play next: drawn by the mood's weights over the pool, or
    /// evenly without one.
    func nextIdleEntry() -> RandomAnimEntry? {
        guard let mood = aiState.sessionMood else { return randomAnimEntries.randomElement() }
        return CompanionMood.pick(
            randomAnimEntries, weight: { mood.idleWeight(forClip: $0.name) }, roll: Double.random(in: 0..<1))
    }

    /// The mood's resting face, as expression targets, faded by how long
    /// the character has been up; empty once it is gone.
    func moodRestingFace(now: Date = Date()) -> [VRMExpressionPreset: Float] {
        guard let mood = aiState.sessionMood, let since = aiState.sessionMoodAt else { return [:] }
        let strength = CompanionMood.faceStrength(elapsed: now.timeIntervalSince(since))
        guard strength > 0 else { return [:] }
        let face = mood.restingFace
        return [.happy: face.happy * strength, .relaxed: face.relaxed * strength, .sad: face.sad * strength]
    }
}
