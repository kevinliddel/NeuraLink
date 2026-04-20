//
// VRMLookBackBehavior.swift
// NeuraLink
//
// Created by Dedicatus on 19/04/2026.
//

import Foundation
import simd

// MARK: - Side

enum LookBackSide {
    case left, right

    var ySign: Float { self == .right ? 1.0 : -1.0 }
}

// MARK: - Controller

/// State machine that detects when the camera has been behind the VRM for `triggerDelay`
/// seconds and emits a one-shot `LookBackSide` trigger.
struct VRMLookBackController {
    private enum Phase {
        case idle
        case counting(elapsed: Float)
        case cooldown(elapsed: Float)
    }

    private var phase: Phase = .idle

    /// cos(120°) = −0.5: camera is "behind" within a 120° horizontal arc.
    private static let behindThreshold: Float = -0.5
    private static let triggerDelay: Float = 3.0
    private static let cooldownDuration: Float = 15.0

    /// Call once per frame. Returns a side the first time the trigger fires; nil otherwise.
    mutating func update(orbitYaw: Float, deltaTime: Float) -> LookBackSide? {
        let isBehind = cos(orbitYaw) < Self.behindThreshold

        switch phase {
        case .idle:
            if isBehind { phase = .counting(elapsed: 0) }
            return nil

        case .counting(let elapsed):
            guard isBehind else { phase = .idle; return nil }
            let next = elapsed + deltaTime
            if next >= Self.triggerDelay {
                phase = .cooldown(elapsed: 0)
                // sin(yaw) > 0 when camera is to character's right → look right
                return sin(orbitYaw) >= 0 ? .right : .left
            }
            phase = .counting(elapsed: next)
            return nil

        case .cooldown(let elapsed):
            let next = elapsed + deltaTime
            phase = next >= Self.cooldownDuration ? .idle : .cooldown(elapsed: next)
            return nil
        }
    }

    mutating func reset() { phase = .idle }
}

// MARK: - Animation Builder

/// Builds a procedural AnimationClip for the look-back gesture.
enum VRMLookBackAnimationBuilder {
    static let duration: Float = 2.2

    /// Returns a one-shot clip where the VRM twists its spine and head to peer over the shoulder.
    ///
    /// Rotation budget (all local-Y, cascading): hips 15 + spine 28 + chest 23 + upperChest 18
    /// + neck 9 + head 35 = 128° total world rotation — a natural over-the-shoulder glance.
    /// Head also gets a −3° X tilt so the chin rises slightly, matching real human mechanics.
    static func makeClip(side: LookBackSide) -> AnimationClip {
        var clip = AnimationClip(duration: duration)
        let sign = side.ySign

        // Pure Y-axis bones (hips through neck)
        let yOnlyBones: [(VRMHumanoidBone, Float)] = [
            (.hips, 15.0),
            (.spine, 28.0),
            (.chest, 23.0),
            (.upperChest, 18.0),  // skipped automatically if bone is not mapped
            (.neck, 9.0)
        ]

        for (bone, degrees) in yOnlyBones {
            let rad = degrees * Float.pi / 180.0
            clip.addEulerTrack(bone: bone, axis: .y) { time in
                sign * rad * VRMLookBackAnimationBuilder.envelope(time)
            }
        }

        // Head: Y twist + slight X chin-up (−3°), combined into one sampler so both apply.
        let headYRad: Float = 35.0 * .pi / 180.0
        let headXRad: Float = -3.0 * .pi / 180.0
        let headTrack = JointTrack(
            bone: .head,
            rotationSampler: { time in
                let e = VRMLookBackAnimationBuilder.envelope(time)
                let qY = simd_quatf(angle: sign * headYRad * e, axis: SIMD3<Float>(0, 1, 0))
                let qX = simd_quatf(angle: headXRad * e, axis: SIMD3<Float>(1, 0, 0))
                return simd_mul(qY, qX)
            }
        )
        clip.addJointTrack(headTrack)

        return clip
    }

    // Smooth 0 → 1 → 1 → 0 envelope:
    //   0 – 20 %  ease-in
    //   20 – 65 % hold
    //   65 – 100% ease-out (longer hold at peak for a natural glance)
    private static func envelope(_ time: Float) -> Float {
        let n = time / duration
        if n < 0.20 { return smoothstep(n / 0.20) }
        if n < 0.65 { return 1.0 }
        return 1.0 - smoothstep((n - 0.65) / 0.35)
    }

    private static func smoothstep(_ x: Float) -> Float {
        let t = max(0.0, min(1.0, x))
        return t * t * (3.0 - 2.0 * t)
    }
}
