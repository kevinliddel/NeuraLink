//
//  LiveMotionBuffer.swift
//  NeuraLink
//
//  A growing, lock-protected sequence of retargeted poses at a fixed frame
//  rate, sampled by clip time: the producer (a motion model decoding 2 s
//  windows) appends, the animation tick samples. Between frames the pose is
//  interpolated. The player samples through its own clock (`samplePlayer`),
//  which waits at the last frame while a window is late and resumes from
//  there when it lands, so the body pauses instead of skipping ahead. Old
//  frames are dropped once they are well behind the playhead.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import simd

/// One frame already retargeted onto a model: a local rotation per driven
/// bone, in `LiveMotionRetargeter.drivenBones` order, and the hips
/// translation in the model's hips-parent space.
public struct LiveMotionPose: Sendable {
    public var rotations: [simd_quatf]
    public var hipsTranslation: SIMD3<Float>

    public init(rotations: [simd_quatf], hipsTranslation: SIMD3<Float>) {
        self.rotations = rotations
        self.hipsTranslation = hipsTranslation
    }

    /// Spherical interpolation per bone, linear for the hips.
    public func interpolated(toward next: LiveMotionPose, fraction: Float) -> LiveMotionPose {
        guard fraction > 0 else { return self }
        guard fraction < 1 else { return next }
        let count = min(rotations.count, next.rotations.count)
        var blended = [simd_quatf](repeating: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), count: count)
        for index in 0..<count {
            blended[index] = simd_normalize(
                simd_slerp(rotations[index], next.rotations[index], fraction))
        }
        return LiveMotionPose(
            rotations: blended,
            hipsTranslation: hipsTranslation + (next.hipsTranslation - hipsTranslation) * fraction)
    }
}

public final class LiveMotionBuffer: @unchecked Sendable {
    public let framesPerSecond: Float
    /// Frames kept behind the playhead before trimming.
    public let retainedFrames: Int

    private let lock = NSLock()
    private var poses: [LiveMotionPose] = []
    /// Absolute index of `poses[0]`; the time base never moves when old frames are dropped.
    private var firstFrame = 0
    /// Player seconds the buffer's clock has waited for late frames so far.
    private var clockOffset: Float = 0
    /// Buffer seconds the player last sampled.
    private var playheadTime: Float = 0

    public init(framesPerSecond: Float = 20, retainedFrames: Int = 200) {
        self.framesPerSecond = framesPerSecond
        self.retainedFrames = retainedFrames
    }

    /// Frames appended so far, including dropped ones.
    public var frameCount: Int { lock.withLock { firstFrame + poses.count } }

    /// Seconds of motion appended so far.
    public var duration: Float { Float(frameCount) / framesPerSecond }

    public var isEmpty: Bool { lock.withLock { poses.isEmpty } }

    /// The most recently appended pose, if any.
    public var lastPose: LiveMotionPose? { lock.withLock { poses.last } }

    /// Buffer seconds the player has reached through `samplePlayer`.
    public var playhead: Float { lock.withLock { playheadTime } }

    public func append(_ newPoses: [LiveMotionPose]) {
        guard !newPoses.isEmpty else { return }
        lock.withLock { poses.append(contentsOf: newPoses) }
    }

    /// Drops frames that ended more than `retainedFrames` before `time`.
    public func trim(before time: Float) {
        let keepFrom = Int((time * framesPerSecond).rounded(.down)) - retainedFrames
        lock.withLock {
            let drop = min(max(keepFrom - firstFrame, 0), poses.count)
            guard drop > 0 else { return }
            poses.removeFirst(drop)
            firstFrame += drop
        }
    }

    /// The pose at `time` seconds from the first frame: interpolated between
    /// neighbours, the last frame past the end, the first before the start,
    /// nil while nothing has been appended.
    public func sample(at time: Float) -> LiveMotionPose? {
        lock.withLock { sampleLocked(at: time) }
    }

    /// The pose for the player's clip time. The two clocks run together
    /// while frames lie ahead; when the player reaches the last frame the
    /// buffer's clock waits there, so a late window resumes from the pose
    /// the body stopped in rather than skipping to wherever the player's
    /// clock has got to meanwhile. Several tracks sampling the same time
    /// get the same pose.
    public func samplePlayer(at playerTime: Float) -> LiveMotionPose? {
        lock.withLock {
            guard !poses.isEmpty else {
                clockOffset = playerTime
                return nil
            }
            let end = Float(firstFrame + poses.count - 1) / framesPerSecond
            var local = playerTime - clockOffset
            if local > end {
                clockOffset += local - end
                local = end
            }
            playheadTime = max(local, 0)
            return sampleLocked(at: playheadTime)
        }
    }

    private func sampleLocked(at time: Float) -> LiveMotionPose? {
        guard !poses.isEmpty else { return nil }
        let position = max(0, time) * framesPerSecond - Float(firstFrame)
        let lower = Int(position.rounded(.down))
        if lower < 0 { return poses[0] }
        if lower >= poses.count - 1 { return poses[poses.count - 1] }
        return poses[lower].interpolated(
            toward: poses[lower + 1], fraction: position - Float(lower))
    }
}
