//
// SpringBoneComputeSystem+Animation.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import Metal
import simd

extension SpringBoneComputeSystem {
    func updateAnimatedPositions(model: VRMModel, buffers: SpringBoneBuffers) {
        guard let springBone = model.springBone,
            !rootBoneIndices.isEmpty,
            let animatedRootPositionsBuffer = animatedRootPositionsBuffer
        else {
            return
        }

        var animatedPositions: [SIMD3<Float>] = []
        var rootIndex = 0

        // Update root bone positions from animated transforms
        for spring in springBone.springs {
            if let firstJoint = spring.joints.first,
                let node = model.nodes[safe: firstJoint.node] {
                animatedPositions.append(node.worldPosition)
                rootIndex += 1
            }
        }

        // Teleportation detection: check if any root bone moved more than threshold
        let shouldResetPhysics = detectTeleportation(
            currentPositions: animatedPositions, buffers: buffers)
        if shouldResetPhysics {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: animatedPositions)
        }

        // Manual physics reset request (e.g., when returning to idle)
        if requestPhysicsReset {
            resetPhysicsState(model: model, buffers: buffers, animatedPositions: animatedPositions)
            requestPhysicsReset = false
        }

        // Update last root positions for next frame's teleportation check
        lastRootPositions = animatedPositions

        // Copy to GPU buffer
        if !animatedPositions.isEmpty {
            animatedRootPositionsBuffer.contents().copyMemory(
                from: animatedPositions,
                byteCount: MemoryLayout<SIMD3<Float>>.stride * animatedPositions.count
            )
        }

        // Build collider-to-group index mapping for animated updates
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(groupIndex)
                }
            }
        }

        // Update collider positions (they can move with animation)
        var sphereColliders: [SphereCollider] = []
        var capsuleColliders: [CapsuleCollider] = []
        var planeColliders: [PlaneCollider] = []

        for (colliderIndex, collider) in springBone.colliders.enumerated() {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }
            let groupIndex = colliderToGroupIndex[colliderIndex] ?? 0

            // Extract rotation from world matrix (upper 3x3) to transform local offsets
            let wm = colliderNode.worldMatrix
            let worldRotation = simd_float3x3(
                SIMD3<Float>(wm[0][0], wm[0][1], wm[0][2]),
                SIMD3<Float>(wm[1][0], wm[1][1], wm[1][2]),
                SIMD3<Float>(wm[2][0], wm[2][1], wm[2][2])
            )

            switch collider.shape {
            case .sphere(let offset, let radius):
                let worldOffset = worldRotation * offset
                let worldCenter = colliderNode.worldPosition + worldOffset
                sphereColliders.append(
                    SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                capsuleColliders.append(
                    CapsuleCollider(
                        p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal =
                    simd_length(worldNormal) > 0.001
                    ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                planeColliders.append(
                    PlaneCollider(
                        point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // Apply runtime radius overrides (e.g., for hair clipping prevention)
        for (index, overrideRadius) in sphereColliderRadiusOverrides {
            if index < sphereColliders.count {
                sphereColliders[index].radius = overrideRadius
            }
        }

        // Update collider buffers with animated positions
        if !sphereColliders.isEmpty {
            buffers.updateSphereColliders(sphereColliders)
        }

        if !capsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(capsuleColliders)
        }

        if !planeColliders.isEmpty {
            buffers.updatePlaneColliders(planeColliders)
        }
    }

    /// Checks for teleportation and resets physics state if needed
    /// Called once per frame before entering substep loop
    func checkTeleportationAndReset(model: VRMModel, buffers: SpringBoneBuffers) {
        // Check for teleportation using target positions
        let shouldResetPhysics = detectTeleportation(
            currentPositions: targetRootPositions, buffers: buffers)
        if shouldResetPhysics {
            resetPhysicsState(
                model: model, buffers: buffers, animatedPositions: targetRootPositions)
            // Also reset all interpolation state to prevent lerping from old positions
            resetInterpolationState()
        }

        // Manual physics reset request
        if requestPhysicsReset {
            resetPhysicsState(
                model: model, buffers: buffers, animatedPositions: targetRootPositions)
            resetInterpolationState()
            requestPhysicsReset = false
        }

        // Update last root positions for next frame's teleportation check
        lastRootPositions = targetRootPositions
    }

    /// Resets all interpolation state to current target (prevents lerping from stale data after teleport)
    func resetInterpolationState() {
        previousRootPositions = targetRootPositions
        previousWorldBindDirections = targetWorldBindDirections
        previousSphereColliders = targetSphereColliders
        previousCapsuleColliders = targetCapsuleColliders
        previousPlaneColliders = targetPlaneColliders
    }
}
