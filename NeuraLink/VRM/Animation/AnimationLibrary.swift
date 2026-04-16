//
// AnimationLibrary.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

public enum AnimationLibrary {
    public static func builtinSwayDance() -> AnimationClip {
        var clip = AnimationClip(duration: 2.0)  // Faster cycle for testing

        func sinusoidalSampler(phase: Float = 0, amplitude: Float, frequency: Float = 1.0) -> (
            Float
        ) -> Float {
            return { time in
                amplitude * sinf(2 * .pi * frequency * (time / 2.0) + phase)  // Updated for 2s duration
            }
        }

        // EXTREME DIAGNOSTIC ANIMATION - IMPOSSIBLE TO MISS
        clip.addEulerTrack(
            bone: .hips,
            axis: .z,
            sample: sinusoidalSampler(amplitude: .pi / 2)  // 90 DEGREES!
        )

        clip.addEulerTrack(
            bone: .hips,
            axis: .y,
            sample: sinusoidalSampler(phase: .pi / 2, amplitude: .pi / 60)
        )

        // EXTREME HEAD MOVEMENT
        clip.addEulerTrack(
            bone: .head,
            axis: .x,
            sample: sinusoidalSampler(phase: .pi / 2, amplitude: .pi / 3)  // 60 degrees nodding!
        )

        clip.addEulerTrack(
            bone: .neck,
            axis: .z,
            sample: sinusoidalSampler(phase: .pi / 3, amplitude: .pi / 60)
        )

        // EXTREME ARM MOVEMENTS - FULL ROTATION
        clip.addEulerTrack(
            bone: .leftUpperArm,
            axis: .z,
            sample: sinusoidalSampler(amplitude: .pi * 0.75)  // 135 degrees!
        )

        clip.addEulerTrack(
            bone: .rightUpperArm,
            axis: .z,
            sample: sinusoidalSampler(phase: .pi, amplitude: .pi * 0.75)  // 135 degrees opposite!
        )

        clip.addEulerTrack(
            bone: .leftLowerArm,
            axis: .x,
            sample: sinusoidalSampler(phase: .pi / 4, amplitude: .pi / 15)
        )

        clip.addEulerTrack(
            bone: .rightLowerArm,
            axis: .x,
            sample: sinusoidalSampler(phase: 3 * .pi / 4, amplitude: .pi / 15)
        )

        clip.addEulerTrack(
            bone: .spine,
            axis: .y,
            sample: sinusoidalSampler(phase: .pi / 6, amplitude: .pi / 90)
        )

        clip.addEulerTrack(
            bone: .chest,
            axis: .z,
            sample: sinusoidalSampler(phase: .pi / 3, amplitude: .pi / 60)
        )

        clip.addMorphTrack(key: "happy") { time in
            max(0, sinf(2 * .pi * time / 3.0)) * 0.35
        }

        clip.addMorphTrack(key: "joy") { time in
            max(0, sinf(2 * .pi * time / 4.0 + .pi / 4)) * 0.2
        }

        return clip
    }

    public static func builtinIdleBreathing() -> AnimationClip {
        var clip = AnimationClip(duration: 4.0)

        clip.addEulerTrack(
            bone: .chest,
            axis: .x,
            sample: { time in
                let breathCycle = sinf(2 * .pi * time / 4.0)
                return breathCycle * (.pi / 120)
            }
        )

        clip.addEulerTrack(
            bone: .spine,
            axis: .x,
            sample: { time in
                let breathCycle = sinf(2 * .pi * time / 4.0 + .pi / 4)
                return breathCycle * (.pi / 180)
            }
        )

        return clip
    }

    public static func loadClip(from url: URL, model: VRMModel?) throws -> AnimationClip {
        // Load a .vrma (GLB) file into an AnimationClip using VRMAnimationLoader
        return try VRMAnimationLoader.loadVRMA(from: url, model: model)
    }
}
