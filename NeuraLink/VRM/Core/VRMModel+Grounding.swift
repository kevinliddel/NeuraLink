//
//  VRMModel+Grounding.swift
//  NeuraLink
//
//  Keeps feet on the ground plane by applying a vertical offset to the hips.
//

import Foundation
import simd

extension VRMModel {
    /// Returns the minimum world-space Y among feet/toes bones (if present).
    public func minFootWorldY() -> Float? {
        withLock {
            guard let humanoid else { return nil }
            let candidates: [VRMHumanoidBone] = [.leftFoot, .rightFoot, .leftToes, .rightToes]
            var minY = Float.greatestFiniteMagnitude
            for bone in candidates {
                guard let nodeIndex = humanoid.getBoneNode(bone),
                      nodeIndex < nodes.count else { continue }
                minY = min(minY, nodes[nodeIndex].worldPosition.y)
            }
            guard minY.isFinite, minY < Float.greatestFiniteMagnitude else { return nil }
            return minY
        }
    }

    /// Adds a delta-Y to the hips local translation and updates world transforms.
    public func addHipsTranslationY(_ deltaY: Float) {
        guard deltaY.isFinite, abs(deltaY) > 1e-7 else { return }
        withLock {
            guard let humanoid,
                  let hipsIndex = humanoid.getBoneNode(.hips),
                  hipsIndex < nodes.count else { return }
            nodes[hipsIndex].translation.y += deltaY
            nodes[hipsIndex].updateLocalMatrix()
            updateNodeTransforms()
        }
    }

    /// Adjusts hips translation so the lowest foot/toes Y equals `targetY` (usually 0).
    /// Call this after animations have been applied and `updateNodeTransforms()` has run.
    public func applyGrounding(targetY: Float = 0, smoothingSpeed: Float = 12, dt: Float) {
        guard dt > 0 else { return }
        withLock {
            guard let humanoid else { return }

            let candidates: [VRMHumanoidBone] = [.leftFoot, .rightFoot, .leftToes, .rightToes]
            var minY = Float.greatestFiniteMagnitude
            for bone in candidates {
                guard let nodeIndex = humanoid.getBoneNode(bone),
                      nodeIndex < nodes.count else { continue }
                minY = min(minY, nodes[nodeIndex].worldPosition.y)
            }
            guard minY.isFinite, minY < Float.greatestFiniteMagnitude else { return }

            let desiredDelta = targetY - minY
            // Smooth the correction to avoid a visible "pop" when switching animation sources.
            let t = min(max(smoothingSpeed * dt, 0), 1)
            let delta = desiredDelta * t

            guard abs(delta) > 1e-6 else { return }
            guard let hipsIndex = humanoid.getBoneNode(.hips),
                  hipsIndex < nodes.count else { return }
            nodes[hipsIndex].translation.y += delta
            nodes[hipsIndex].updateLocalMatrix()
            updateNodeTransforms()
        }
    }
}
