//
//  LiveMotionClip.swift
//  NeuraLink
//
//  An AnimationClip whose tracks read a LiveMotionBuffer instead of
//  keyframes, so the ordinary player, crossfade and tick drive a motion
//  stream that is still being generated. Its duration is open-ended: the
//  stream ends when the scene crossfades away from it, not when the clip
//  does.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import simd

public enum LiveMotionClip {
    /// Long enough that the player never reaches it (a week of frames).
    public static let openDuration: Float = 604_800

    /// A clip over `buffer` for the model `retargeter` was built from. Before
    /// the first frame arrives the tracks hold the bind pose, which the
    /// crossfade into the clip starts from anyway.
    public static func make(
        buffer: LiveMotionBuffer, retargeter: LiveMotionRetargeter, model: VRMModel
    ) -> AnimationClip {
        var clip = AnimationClip(duration: openDuration)
        let rests = buildModelRestTransforms(model: model)
        for (index, bone) in retargeter.bones.enumerated() {
            let rest = simd_normalize(
                rests[bone]?.rotation ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
            let translation: ((Float) -> SIMD3<Float>)? =
                bone == .hips
                ? { time in
                    buffer.sample(at: time)?.hipsTranslation ?? rests[.hips]?.translation ?? .zero
                }
                : nil
            clip.addJointTrack(
                JointTrack(
                    bone: bone,
                    rotationSampler: { time in
                        guard let pose = buffer.sample(at: time), index < pose.rotations.count
                        else { return rest }
                        return pose.rotations[index]
                    },
                    translationSampler: translation))
        }
        return clip
    }
}

/// Everything the scene holds while a generated motion stream owns the
/// body: the buffer being filled, the retargeter for the current model and
/// the clip the player runs. Built on the main actor for the model that is
/// displayed; the producer appends to `buffer` from wherever it decodes.
public final class LiveMotionSession: @unchecked Sendable {
    public let buffer: LiveMotionBuffer
    public let retargeter: LiveMotionRetargeter
    public let clip: AnimationClip
    public let model: VRMModel
    /// Clip seconds the player has advanced, kept by the scene's tick.
    public var elapsed: Float = 0

    public init(model: VRMModel, framesPerSecond: Float = 20) {
        self.model = model
        buffer = LiveMotionBuffer(framesPerSecond: framesPerSecond)
        retargeter = LiveMotionRetargeter(model: model)
        clip = LiveMotionClip.make(buffer: buffer, retargeter: retargeter, model: model)
    }

    /// Retargets and appends decoded frames: `globalRotations` holds
    /// `frames` × 27 × 9 floats, `rootPositions` `frames` × 3. With
    /// `blendingFirst` > 0 the first frames ease from the last appended pose
    /// (a replanned window starts from a fresh inference).
    public func append(frames: Int, globalRotations: [Float], rootPositions: [Float], blendingFirst: Int = 0) {
        let rotationStride = LiveMotionRetargeter.jointCount * 9
        guard frames > 0, globalRotations.count >= frames * rotationStride, rootPositions.count >= frames * 3 else { return }
        var poses: [LiveMotionPose] = []
        poses.reserveCapacity(frames)
        for frame in 0..<frames {
            let rotations = Array(globalRotations[(frame * rotationStride)..<((frame + 1) * rotationStride)])
            let root = SIMD3<Float>(rootPositions[frame * 3], rootPositions[frame * 3 + 1], rootPositions[frame * 3 + 2])
            if let pose = retargeter.pose(globalRotations: rotations, rootPosition: root) { poses.append(pose) }
        }
        if blendingFirst > 0, let last = buffer.lastPose {
            for frame in 0..<min(blendingFirst, poses.count) {
                poses[frame] = last.interpolated(toward: poses[frame], fraction: Float(frame + 1) / Float(blendingFirst + 1))
            }
        }
        buffer.append(poses)
    }

    /// Seconds of motion appended beyond the playhead.
    public var lead: Float { buffer.duration - elapsed }
}
