//
//  LiveMotionBuffer.swift
//  NeuraLink
//
//  A growing, lock-protected sequence of retargeted poses at a fixed frame
//  rate, sampled by clip time: the producer (a motion model decoding 2 s
//  windows) appends, the animation tick samples. Between frames the pose is
//  interpolated; past the last frame it holds, so a late window freezes the
//  body for a moment instead of snapping. Old frames are dropped once they
//  are well behind the playhead.
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

    public init(framesPerSecond: Float = 20, retainedFrames: Int = 200) {
        self.framesPerSecond = framesPerSecond
        self.retainedFrames = retainedFrames
    }

    /// Frames appended so far, including dropped ones.
    public var frameCount: Int { lock.withLock { firstFrame + poses.count } }

    /// Seconds of motion appended so far.
    public var duration: Float { Float(frameCount) / framesPerSecond }

    public var isEmpty: Bool { lock.withLock { poses.isEmpty } }

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
        lock.withLock {
            guard !poses.isEmpty else { return nil }
            let position = max(0, time) * framesPerSecond - Float(firstFrame)
            let lower = Int(position.rounded(.down))
            if lower < 0 { return poses[0] }
            if lower >= poses.count - 1 { return poses[poses.count - 1] }
            return poses[lower].interpolated(
                toward: poses[lower + 1], fraction: position - Float(lower))
        }
    }
}
