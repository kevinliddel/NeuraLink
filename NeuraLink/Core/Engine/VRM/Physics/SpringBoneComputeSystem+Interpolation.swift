//
// SpringBoneComputeSystem+Interpolation.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import Metal
import simd

extension SpringBoneComputeSystem {
    // MARK: - Frame Interpolation State Capture

    /// Captures all target transforms from animation for this frame
    /// Called once at the start of the frame before substep loop
    /// Captures: root positions, world bind directions, collider transforms
    func captureTargetTransforms(model: VRMModel) {
        guard let springBone = model.springBone else { return }

        // 1. Capture root positions
        targetRootPositions = []
        for spring in springBone.springs {
            if let firstJoint = spring.joints.first,
                let node = model.nodes[safe: firstJoint.node] {
                targetRootPositions.append(node.worldPosition)
            }
        }

        // First frame initialization
        if previousRootPositions.isEmpty || previousRootPositions.count != targetRootPositions.count {
            previousRootPositions = targetRootPositions
        }

        // 2. Capture world bind directions (transforms static bind dirs by current parent rotation)
        captureTargetWorldBindDirections(model: model, springBone: springBone)

        // 3. Capture collider transforms
        captureTargetColliderTransforms(model: model, springBone: springBone)

        // Cache model scale for scale-aware thresholds
        cachedModelScale = calculateModelScaleFromRestLengths()
    }

    /// Captures world-space bind directions based on current animated parent orientations
    func captureTargetWorldBindDirections(model: VRMModel, springBone: VRMSpringBone) {
        targetWorldBindDirections = []

        var boneIndex = 0
        for spring in springBone.springs {
            for joint in spring.joints {
                guard boneIndex < boneBindDirections.count,
                    let jointNode = model.nodes[safe: joint.node]
                else {
                    boneIndex += 1
                    continue
                }

                let localBindDir = boneBindDirections[boneIndex]

                // Transform by the node's ACTUAL parent (matches how we stored it)
                if let nodeParent = jointNode.parent {
                    let parentRot = extractRotation(from: nodeParent.worldMatrix)
                    let worldBindDir = simd_act(parentRot, localBindDir)
                    targetWorldBindDirections.append(simd_normalize(worldBindDir))
                } else {
                    // Root bone - local is world
                    targetWorldBindDirections.append(localBindDir)
                }

                boneIndex += 1
            }
        }

        // First frame initialization
        if previousWorldBindDirections.isEmpty
            || previousWorldBindDirections.count != targetWorldBindDirections.count {
            previousWorldBindDirections = targetWorldBindDirections
        }
    }

    /// Captures collider transforms based on current animated node positions/orientations
    func captureTargetColliderTransforms(model: VRMModel, springBone: VRMSpringBone) {
        // Build collider-to-group index mapping
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(groupIndex)
                }
            }
        }

        targetSphereColliders = []
        targetCapsuleColliders = []
        targetPlaneColliders = []

        for (colliderIndex, collider) in springBone.colliders.enumerated() {
            guard let colliderNode = model.nodes[safe: collider.node] else { continue }
            let groupIndex = colliderToGroupIndex[colliderIndex] ?? 0

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
                targetSphereColliders.append(
                    SphereCollider(center: worldCenter, radius: radius, groupIndex: groupIndex))

            case .capsule(let offset, let radius, let tail):
                let worldOffset = worldRotation * offset
                let worldTail = worldRotation * tail
                let worldP0 = colliderNode.worldPosition + worldOffset
                let worldP1 = worldP0 + worldTail
                targetCapsuleColliders.append(
                    CapsuleCollider(
                        p0: worldP0, p1: worldP1, radius: radius, groupIndex: groupIndex))

            case .plane(let offset, let normal):
                let worldOffset = worldRotation * offset
                let worldNormal = worldRotation * normal
                let worldPoint = colliderNode.worldPosition + worldOffset
                let normalizedNormal =
                    simd_length(worldNormal) > 0.001
                    ? simd_normalize(worldNormal) : SIMD3<Float>(0, 1, 0)
                targetPlaneColliders.append(
                    PlaneCollider(
                        point: worldPoint, normal: normalizedNormal, groupIndex: groupIndex))
            }
        }

        // Apply runtime radius overrides (e.g., for hair clipping prevention)
        for (index, overrideRadius) in sphereColliderRadiusOverrides {
            if index < targetSphereColliders.count {
                targetSphereColliders[index].radius = overrideRadius
            }
        }

        // First frame initialization
        if previousSphereColliders.isEmpty
            || previousSphereColliders.count != targetSphereColliders.count {
            previousSphereColliders = targetSphereColliders
        }
        if previousCapsuleColliders.isEmpty
            || previousCapsuleColliders.count != targetCapsuleColliders.count {
            previousCapsuleColliders = targetCapsuleColliders
        }
        if previousPlaneColliders.isEmpty
            || previousPlaneColliders.count != targetPlaneColliders.count {
            previousPlaneColliders = targetPlaneColliders
        }
    }

    /// Estimates model scale from bone rest lengths (proxy for overall model size)
    func calculateModelScaleFromRestLengths() -> Float {
        // Use max non-zero rest length as a reasonable proxy for model scale
        // Typical VRM models have rest lengths of 0.05-0.15m for hair/cloth bones
        let nonZeroLengths = cpuRestLengths.filter { $0 > 0.001 }
        guard !nonZeroLengths.isEmpty else {
            return 1.0  // Default scale if no valid rest lengths
        }

        // Average rest length, normalized so that ~0.1m = 1.0 scale
        let avgLength = nonZeroLengths.reduce(0, +) / Float(nonZeroLengths.count)
        let normalizedScale = avgLength / 0.1  // 0.1m is typical bone length at scale 1.0

        return max(normalizedScale, VRMConstants.Physics.minScaleForThreshold)
    }

    // MARK: - Substep Interpolation Methods

    /// Interpolates all transforms for the current substep
    /// - Parameter t: Interpolation factor [0, 1] where 0 = previous frame, 1 = current frame target
    func interpolateAllTransforms(t: Float, buffers: SpringBoneBuffers) {
        interpolateRootPositions(t: t)
        interpolateWorldBindDirections(t: t, buffers: buffers)
        interpolateColliders(t: t, buffers: buffers)
    }

    /// Interpolates root positions for the current substep
    func interpolateRootPositions(t: Float) {
        guard previousRootPositions.count == targetRootPositions.count,
            let buffer = animatedRootPositionsBuffer,
            !previousRootPositions.isEmpty
        else { return }

        let ptr = buffer.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: previousRootPositions.count)
        for i in 0..<previousRootPositions.count {
            // Linear interpolation: prev + t * (target - prev)
            ptr[i] = simd_mix(
                previousRootPositions[i], targetRootPositions[i], SIMD3<Float>(repeating: t))
        }
    }

    /// Interpolates world bind directions using normalized linear interpolation (nlerp)
    /// This prevents rotational snapping during fast character turns
    func interpolateWorldBindDirections(t: Float, buffers: SpringBoneBuffers) {
        guard previousWorldBindDirections.count == targetWorldBindDirections.count,
            let bindDirectionsBuffer = buffers.bindDirections,
            !previousWorldBindDirections.isEmpty
        else { return }

        let ptr = bindDirectionsBuffer.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: previousWorldBindDirections.count)
        for i in 0..<previousWorldBindDirections.count {
            // Normalized linear interpolation (nlerp) for direction vectors
            let interpolated = simd_mix(
                previousWorldBindDirections[i], targetWorldBindDirections[i],
                SIMD3<Float>(repeating: t))
            let len = simd_length(interpolated)
            ptr[i] = len > 0.001 ? interpolated / len : targetWorldBindDirections[i]
        }
    }

    /// Interpolates collider transforms for the current substep
    /// Prevents collision geometry from snapping during fast rotations
    func interpolateColliders(t: Float, buffers: SpringBoneBuffers) {
        // Interpolate sphere colliders
        if previousSphereColliders.count == targetSphereColliders.count,
            let sphereBuffer = buffers.sphereColliders,
            !previousSphereColliders.isEmpty {
            let ptr = sphereBuffer.contents().bindMemory(
                to: SphereCollider.self, capacity: previousSphereColliders.count)
            for i in 0..<previousSphereColliders.count {
                let prev = previousSphereColliders[i]
                let target = targetSphereColliders[i]
                ptr[i] = SphereCollider(
                    center: simd_mix(prev.center, target.center, SIMD3<Float>(repeating: t)),
                    radius: prev.radius + t * (target.radius - prev.radius),
                    groupIndex: target.groupIndex
                )
            }
        }

        // Interpolate capsule colliders
        if previousCapsuleColliders.count == targetCapsuleColliders.count,
            let capsuleBuffer = buffers.capsuleColliders,
            !previousCapsuleColliders.isEmpty {
            let ptr = capsuleBuffer.contents().bindMemory(
                to: CapsuleCollider.self, capacity: previousCapsuleColliders.count)
            for i in 0..<previousCapsuleColliders.count {
                let prev = previousCapsuleColliders[i]
                let target = targetCapsuleColliders[i]
                ptr[i] = CapsuleCollider(
                    p0: simd_mix(prev.p0, target.p0, SIMD3<Float>(repeating: t)),
                    p1: simd_mix(prev.p1, target.p1, SIMD3<Float>(repeating: t)),
                    radius: prev.radius + t * (target.radius - prev.radius),
                    groupIndex: target.groupIndex
                )
            }
        }

        // Interpolate plane colliders
        if previousPlaneColliders.count == targetPlaneColliders.count,
            let planeBuffer = buffers.planeColliders,
            !previousPlaneColliders.isEmpty {
            let ptr = planeBuffer.contents().bindMemory(
                to: PlaneCollider.self, capacity: previousPlaneColliders.count)
            for i in 0..<previousPlaneColliders.count {
                let prev = previousPlaneColliders[i]
                let target = targetPlaneColliders[i]
                // nlerp for normal direction
                let interpolatedNormal = simd_mix(
                    prev.normal, target.normal, SIMD3<Float>(repeating: t))
                let normalLen = simd_length(interpolatedNormal)
                ptr[i] = PlaneCollider(
                    point: simd_mix(prev.point, target.point, SIMD3<Float>(repeating: t)),
                    normal: normalLen > 0.001 ? interpolatedNormal / normalLen : target.normal,
                    groupIndex: target.groupIndex
                )
            }
        }
    }

    /// Stores current target transforms as previous for next frame's interpolation
    func commitAllTransforms() {
        previousRootPositions = targetRootPositions
        previousWorldBindDirections = targetWorldBindDirections
        previousSphereColliders = targetSphereColliders
        previousCapsuleColliders = targetCapsuleColliders
        previousPlaneColliders = targetPlaneColliders
    }

    // MARK: - Teleportation Detection

    /// Detects if the model has teleported (moved more than threshold distance)
    /// This prevents physics explosion when character is repositioned instantly
    /// Uses scale-aware threshold to handle models of different sizes
    func detectTeleportation(currentPositions: [SIMD3<Float>], buffers: SpringBoneBuffers) -> Bool {
        // Skip detection on first frame or if no previous positions
        guard !lastRootPositions.isEmpty,
            lastRootPositions.count == currentPositions.count
        else {
            return false
        }

        // Scale threshold by model size (tiny models have proportionally smaller thresholds)
        let scaledThreshold =
            teleportationThreshold
            * max(cachedModelScale, VRMConstants.Physics.minScaleForThreshold)

        // Check if any root bone moved more than the scaled threshold
        for i in 0..<currentPositions.count {
            let distance = simd_distance(currentPositions[i], lastRootPositions[i])
            if distance > scaledThreshold {
                return true
            }
        }

        return false
    }

    /// Resets physics state after teleportation to prevent spring explosion
    /// Calculates kinematic (rest) positions for all bones based on parent chain
    func resetPhysicsState(
        model: VRMModel, buffers: SpringBoneBuffers, animatedPositions: [SIMD3<Float>]
    ) {
        guard let bonePosPrev = buffers.bonePosPrev,
            let bonePosCurr = buffers.bonePosCurr,
            buffers.numBones > 0,
            cpuParentIndices.count == buffers.numBones,
            cpuRestLengths.count == buffers.numBones
        else {
            return
        }

        // Calculate kinematic positions: root bones from animation, children from parent + direction * length
        var kinematicPositions: [SIMD3<Float>] = Array(repeating: .zero, count: buffers.numBones)

        // Map root bone indices to their animated positions
        var rootPositionMap: [Int: SIMD3<Float>] = [:]
        for (i, rootIdx) in rootBoneIndices.enumerated() {
            if i < animatedPositions.count {
                rootPositionMap[Int(rootIdx)] = animatedPositions[i]
            }
        }

        // Process bones in order (parents before children due to chain structure)
        // Use gravity direction (downward) for child bones to make hair hang naturally
        let gravityDir = SIMD3<Float>(0, -1, 0)

        for i in 0..<buffers.numBones {
            let parentIdx = cpuParentIndices[i]

            if parentIdx < 0 {
                // Root bone - use animated position
                kinematicPositions[i] = rootPositionMap[i] ?? .zero
            } else {
                // Child bone - hang down from parent using gravity direction
                let parentPos = kinematicPositions[parentIdx]
                let restLength = cpuRestLengths[i]

                // Use gravity direction so hair hangs down naturally
                kinematicPositions[i] = parentPos + gravityDir * restLength
            }
        }

        // Reset both previous and current positions to kinematic (eliminates velocity)
        let prevPtr = bonePosPrev.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: buffers.numBones)
        let currPtr = bonePosCurr.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: buffers.numBones)
        for i in 0..<buffers.numBones {
            prevPtr[i] = kinematicPositions[i]
            currPtr[i] = kinematicPositions[i]
        }

        // Reset time accumulator to prevent multiple substeps after teleport
        timeAccumulator = 0

        // NOTE: Do NOT reset settlingFrames here - that's only for initial load
        // The reset already kills velocity by setting prev=curr, which is sufficient
        // Re-triggering settling would reduce stiffness/drag and cause extended jiggle

        // Reset readback state
        snapshotLock.lock()
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()
    }
}
