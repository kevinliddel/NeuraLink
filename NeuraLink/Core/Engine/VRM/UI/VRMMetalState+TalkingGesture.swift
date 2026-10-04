//
//  VRMMetalState+TalkingGesture.swift
//  NeuraLink
//
//  Occasional body gestures while the character speaks: at the start of a
//  spoken reply, `TalkingGesturePolicy` decides whether to play one of the
//  talking clips (speaking.vrma / talking.vrma, Mixamo → VRMA) once, then
//  the body crossfades back to the neutral idle. About one reply in three,
//  never two in a row — frequent enough to feel alive, not a loop.
//
//  Created by Dedicatus on 01/10/2026.
//

import Foundation

/// Decides, once per spoken reply, whether to gesture. After a gesture the
/// next `cooldown` replies are skipped; then each reply rolls `probability`,
/// and the `guaranteeAfter`-th reply always gestures — roughly 3–4 per 10.
nonisolated struct TalkingGesturePolicy: Equatable {
    static let clipNames = ["speaking", "talking"]

    var probability = 0.4
    var cooldown = 1
    var guaranteeAfter = 4
    /// Replies since the last gesture (or since the character loaded).
    private(set) var repliesSinceGesture = 0

    /// Call once per reply with a uniform roll in 0..<1.
    mutating func shouldGesture(roll: Double) -> Bool {
        repliesSinceGesture += 1
        guard repliesSinceGesture > cooldown else { return false }
        guard repliesSinceGesture >= guaranteeAfter || roll < probability else { return false }
        repliesSinceGesture = 0
        return true
    }
}

extension VRMMetalState {

    /// Crossfade out this long before the clip ends, so it never freezes on
    /// its last frame (the clip plays once, not looped).
    private static let talkingGestureFadeOut: Float = 0.5

    /// Per-frame: finish a running gesture, or start one on the reply's
    /// first speaking frame.
    func updateTalkingGesture(dt: Float, model: VRMModel) {
        let speaking = aiState.status == .speaking
        defer { wasSpeakingLastFrame = speaking }

        if isPlayingTalkingGesture {
            talkingGestureElapsed += dt
            guard talkingGestureElapsed >= talkingGestureDuration - Self.talkingGestureFadeOut else { return }
            isPlayingTalkingGesture = false
            if let clip = defaultClip {
                animationPlayer.isLooping = true
                animationPlayer.crossfade(to: clip, duration: Self.talkingGestureFadeOut, from: model)
            }
            scheduleNextRandomAnim()
            nlLog("[TalkGesture] ↩ neutral")
            return
        }

        guard speaking, !wasSpeakingLastFrame else { return }
        // A pose or the entrance owns the body; the reply still counts.
        let roll = Double.random(in: 0..<1)
        guard talkingGesturePolicy.shouldGesture(roll: roll) else { return }
        guard !isPlayingAppear, !isPlayingPose, let entry = talkingGestureEntries.randomElement() else { return }

        isPlayingRandomAnim = false
        randomAnimTimer = -1  // idles wait until the gesture hands back
        isPlayingTalkingGesture = true
        talkingGestureElapsed = 0
        talkingGestureDuration = entry.clip.duration
        animationPlayer.isLooping = false
        animationPlayer.crossfade(to: entry.clip, duration: 0.4, from: model)
        nlLog("[TalkGesture] ▶ '\(entry.name)' (\(String(format: "%.1f", entry.clip.duration))s)")
    }
}
