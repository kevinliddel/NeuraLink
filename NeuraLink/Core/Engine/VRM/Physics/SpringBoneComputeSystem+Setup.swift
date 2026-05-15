//
// SpringBoneComputeSystem+Setup.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import Metal
import simd

extension SpringBoneComputeSystem {
    func populateSpringBoneData(model: VRMModel) throws {
        guard let springBone = model.springBone,
            let buffers = model.springBoneBuffers,
            model.device != nil
        else {
            return
        }

        var boneParams: [BoneParams] = []
        var restLengths: [Float] = []
        var parentIndices: [Int] = []  // CPU-side parent indices for physics reset
        var sphereColliders: [SphereCollider] = []
        var capsuleColliders: [CapsuleCollider] = []
        var planeColliders: [PlaneCollider] = []
        boneBindDirections = []  // Reset bind directions (current→child)

        // Build collider-to-group index mapping
        // Each collider can belong to multiple groups, but we assign the first group index for GPU filtering
        var colliderToGroupIndex: [Int: UInt32] = [:]
        for (groupIndex, group) in springBone.colliderGroups.enumerated() {
            for colliderIndex in group.colliders {
                // Use first group if collider belongs to multiple groups
                if colliderToGroupIndex[colliderIndex] == nil {
                    colliderToGroupIndex[colliderIndex] = UInt32(groupIndex)
                }
            }
        }

        // Process spring chains to extract bone parameters
        var boneIndex = 0
        rootBoneIndices = []

        // Track chains with all-zero gravityPower for auto-fix
        var chainGravityPowers: [[Float]] = []

        for spring in springBone.springs {
            var jointIndexInChain = 0
            var chainGravityPower: [Float] = []

            // Build collision group mask for this spring chain
            // Each bit represents a collision group that this spring interacts with
            var colliderGroupMask: UInt32 = 0
            if spring.colliderGroups.isEmpty {
                // No groups specified - collide with all groups (backward compatible default)
                colliderGroupMask = 0xFFFF_FFFF
            } else {
                for groupIndex in spring.colliderGroups {
                    if groupIndex < 32 {
                        colliderGroupMask |= (1 << groupIndex)
                    }
                }
            }

            for joint in spring.joints {
                chainGravityPower.append(joint.gravityPower)

                // First joint in each spring chain is a root
                let isRootBone = (jointIndexInChain == 0)

                if isRootBone {
                    rootBoneIndices.append(UInt32(boneIndex))
                }

                // Normalize gravity direction to ensure unit vector for GPU
                let normalizedGravityDir =
                    simd_length(joint.gravityDir) > 0.001
                    ? simd_normalize(joint.gravityDir)
                    : SIMD3<Float>(0, -1, 0)  // Default downward if zero vector

                // Calculate parent index (-1 for root bones)
                let parentIdx = (isRootBone || jointIndexInChain == 0) ? -1 : (boneIndex - 1)
                parentIndices.append(parentIdx)

                let params = BoneParams(
                    stiffness: joint.stiffness,
                    drag: joint.dragForce,
                    radius: joint.hitRadius,
                    // Only set parent for non-root bones within the same chain
                    parentIndex: parentIdx < 0 ? 0xFFFF_FFFF : UInt32(parentIdx),
                    gravityPower: joint.gravityPower,
                    colliderGroupMask: colliderGroupMask,
                    gravityDir: normalizedGravityDir
                )
                boneParams.append(params)

                // Calculate rest length (distance to parent in bind pose)
                if jointIndexInChain > 0, let node = model.nodes[safe: joint.node],
                    let parentJoint = spring.joints[safe: jointIndexInChain - 1],
                    let parentNode = model.nodes[safe: parentJoint.node] {
                    let restLength = simd_distance(node.worldPosition, parentNode.worldPosition)
                    restLengths.append(restLength)
                } else {
                    restLengths.append(0.0)  // Root bone has no rest length
                }

                // Store bind-pose direction for THIS bone (looking ahead to NEXT bone)
                // CRITICAL: Store in PARENT's local space, not current bone's local space
                guard let currentNode = model.nodes[safe: joint.node] else {
                    // Fallback for invalid node - try to get real direction from next joint if possible
                    if let nextJoint = spring.joints[safe: jointIndexInChain + 1],
                        let nextNode = model.nodes[safe: nextJoint.node],
                        jointIndexInChain > 0,
                        let prevJoint = spring.joints[safe: jointIndexInChain - 1],
                        let prevNode = model.nodes[safe: prevJoint.node] {
                        let bindDirWorld = simd_normalize(
                            nextNode.worldPosition - prevNode.worldPosition)
                        boneBindDirections.append(bindDirWorld)
                    } else {
                        boneBindDirections.append(SIMD3<Float>(0, 1, 0))  // Ultimate fallback
                    }
                    boneIndex += 1
                    jointIndexInChain += 1
                    continue
                }

                // BIND DIRECTION: current → child
                // - Used for ROTATION calculation in Swift
                // - Used for GPU STIFFNESS via bindDirections[parentIndex] in shader
                if let nextJoint = spring.joints[safe: jointIndexInChain + 1],
                    let nextNode = model.nodes[safe: nextJoint.node] {
                    let bindDirWorld = simd_normalize(
                        nextNode.worldPosition - currentNode.worldPosition)
                    if let parentNode = currentNode.parent {
                        let parentRot = extractRotation(from: parentNode.worldMatrix)
                        let parentRotInv = simd_conjugate(parentRot)
                        boneBindDirections.append(simd_act(parentRotInv, bindDirWorld))
                    } else {
                        boneBindDirections.append(bindDirWorld)
                    }
                } else {
                    // Last bone - no child, use downward
                    boneBindDirections.append(SIMD3<Float>(0, -1, 0))
                }

                boneIndex += 1
                jointIndexInChain += 1
            }

            chainGravityPowers.append(chainGravityPower)
        }

        // NOTE: Auto-fix for zero gravityPower removed - it was overriding intentional zero gravity
        // Real VRM files with broken physics should be fixed at the source or use a dedicated flag
        // to enable auto-fixing behavior rather than applying it unconditionally.

        // Process colliders with group index assignment
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

        // Update buffers
        buffers.updateBoneParameters(boneParams)
        buffers.updateRestLengths(restLengths)

        // GPU needs WORLD directions for stiffness calculation
        // boneBindDirections stores current→child in parent's LOCAL space
        // Transform to world by applying the node's ACTUAL parent's rotation (not prev joint)
        var initialWorldBindDirections: [SIMD3<Float>] = []
        var boneIdx = 0
        for spring in springBone.springs {
            for joint in spring.joints {
                guard boneIdx < boneBindDirections.count,
                    let jointNode = model.nodes[safe: joint.node]
                else {
                    boneIdx += 1
                    continue
                }
                let localDir = boneBindDirections[boneIdx]
                // Transform by the node's actual parent (matches how we stored it)
                if let nodeParent = jointNode.parent {
                    let parentRot = extractRotation(from: nodeParent.worldMatrix)
                    let worldDir = simd_act(parentRot, localDir)
                    initialWorldBindDirections.append(simd_normalize(worldDir))
                } else {
                    // Root bone - local is world
                    initialWorldBindDirections.append(localDir)
                }
                boneIdx += 1
            }
        }
        buffers.updateBindDirections(initialWorldBindDirections)

        // Also initialize the interpolation targets with the same world directions
        targetWorldBindDirections = initialWorldBindDirections
        previousWorldBindDirections = initialWorldBindDirections

        // Store CPU-side copies for physics reset
        cpuRestLengths = restLengths
        cpuParentIndices = parentIndices

        if !sphereColliders.isEmpty {
            buffers.updateSphereColliders(sphereColliders)
        }

        if !capsuleColliders.isEmpty {
            buffers.updateCapsuleColliders(capsuleColliders)
        }

        if !planeColliders.isEmpty {
            buffers.updatePlaneColliders(planeColliders)
        }

        // Initialize bone positions from bind pose (node world positions)
        // Physics will naturally settle bones to their hanging position during settling period
        var initialPositions: [SIMD3<Float>] = []
        boneIndex = 0
        for spring in springBone.springs {
            for joint in spring.joints {
                if let node = model.nodes[safe: joint.node] {
                    initialPositions.append(node.worldPosition)
                } else {
                    initialPositions.append(.zero)
                }
                boneIndex += 1
            }
        }

        // Copy initial positions to both prev and curr buffers
        if let bonePosPrev = buffers.bonePosPrev,
            let bonePosCurr = buffers.bonePosCurr,
            !initialPositions.isEmpty {
            let prevPtr = bonePosPrev.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: initialPositions.count)
            let currPtr = bonePosCurr.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: initialPositions.count)
            for i in 0..<initialPositions.count {
                prevPtr[i] = initialPositions[i]
                currPtr[i] = initialPositions[i]
            }
        }

        // Initialize buffers for root bone kinematic updates
        let numRootBones = rootBoneIndices.count
        if numRootBones > 0 {
            animatedRootPositionsBuffer = device.makeBuffer(
                length: MemoryLayout<SIMD3<Float>>.stride * numRootBones,
                options: [.storageModeShared])
            rootBoneIndicesBuffer = device.makeBuffer(
                bytes: rootBoneIndices,
                length: MemoryLayout<UInt32>.stride * numRootBones,
                options: [.storageModeShared])
            var numRootBonesUInt = UInt32(numRootBones)
            numRootBonesBuffer = device.makeBuffer(
                bytes: &numRootBonesUInt,
                length: MemoryLayout<UInt32>.stride,
                options: [.storageModeShared])
        }

        snapshotLock.lock()
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()
    }
}
