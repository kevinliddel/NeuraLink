//
// SpringBoneComputeSystem+Readback.swift
// NeuraLink
//
// Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

extension SpringBoneComputeSystem {
    /// Read back GPU-computed bone positions and update VRMNode transforms for all chains.
    func writeBonesToNodes(model: VRMModel) {
        guard let springBone = model.springBone,
            let buffers = model.springBoneBuffers
        else {
            return
        }

        snapshotLock.lock()
        let readyFrame = latestCompletedFrame
        let positions = latestPositionsSnapshot
        let canApply =
            readyFrame > lastAppliedFrame && positions.count >= buffers.numBones
            && !positions.isEmpty
        if canApply {
            lastAppliedFrame = readyFrame
        }
        snapshotLock.unlock()

        guard canApply else {
            return
        }

        // Chest/breast chains get physics (gravity + sway) but with a swing angle cap
        // to prevent extreme mesh deformation. Hair chains get unclamped physics.
        // NOTE: We check only the DIRECT parent, NOT all ancestors — upperChest is an ancestor
        // of every node above the hips, so an ancestor walk would incorrectly catch hair chains.
        let chestAnchorNodes = resolveChestAnchorNodes(model: model)

        // Map bone index to spring/joint for node updates
        var globalBoneIndex = 0
        for spring in springBone.springs {
            guard globalBoneIndex < positions.count else { break }

            let isBreast = isBreastChain(
                spring: spring, model: model, chestAnchorNodes: chestAnchorNodes)

            // Build array of (node, position, globalIndex) tuples for this chain
            var nodePositions: [(VRMNode, SIMD3<Float>, Int)] = []
            for joint in spring.joints {
                guard let node = model.nodes[safe: joint.node],
                    globalBoneIndex < positions.count
                else { continue }

                nodePositions.append((node, positions[globalBoneIndex], globalBoneIndex))
                globalBoneIndex += 1
            }

            if nodePositions.count >= 2 {
                // Breast chains: cap swing at 25° so mesh never deforms past skin surface
                let maxSwing: Float? = isBreast ? (Float.pi * 25.0 / 180.0) : nil
                updateNodeTransformsForChain(nodePositions: nodePositions, maxSwingAngle: maxSwing)
            }
        }
    }

    /// Returns VRMNode objects for chest and upperChest humanoid bones (whichever are mapped).
    private func resolveChestAnchorNodes(model: VRMModel) -> [VRMNode] {
        let anchors: [VRMHumanoidBone] = [.chest, .upperChest]
        return anchors.compactMap { bone -> VRMNode? in
            guard let nodeIndex = model.humanoid?.humanBones[bone]?.node else { return nil }
            return model.nodes[safe: nodeIndex]
        }
    }

    /// Returns true when the spring root's DIRECT parent is chest/upperChest,
    /// or when the root node name contains common breast-bone keywords.
    private func isBreastChain(
        spring: VRMSpring, model: VRMModel, chestAnchorNodes: [VRMNode]
    ) -> Bool {
        guard let firstJoint = spring.joints.first,
            let rootNode = model.nodes[safe: firstJoint.node]
        else { return false }

        // Direct-parent check only — ancestor walk is intentionally avoided.
        if let parent = rootNode.parent,
            chestAnchorNodes.contains(where: { $0 === parent }) {
            return true
        }

        // Name-based fallback for models that don't map chest in humanoid
        let name = (rootNode.name ?? "").lowercased()
        return ["bust", "breast", "boob", "boin", "mune"].contains { name.contains($0) }
    }

    func captureCompletedPositions(from buffers: SpringBoneBuffers, frameID: UInt64) {
        guard let bonePosCurr = buffers.bonePosCurr,
            buffers.numBones > 0
        else {
            return
        }

        let sourcePointer = bonePosCurr.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: buffers.numBones)

        snapshotLock.lock()
        if latestPositionsSnapshot.count != buffers.numBones {
            latestPositionsSnapshot = Array(
                repeating: SIMD3<Float>(repeating: 0), count: buffers.numBones)
        }

        latestPositionsSnapshot.withUnsafeMutableBufferPointer { destination in
            guard let dst = destination.baseAddress else { return }
            dst.update(from: sourcePointer, count: buffers.numBones)
        }

        // NaN safety: filter out corrupted positions and replace with safe fallback
        // This prevents NaN from propagating to writeBonesToNodes
        var nanCount = 0
        for i in 0..<buffers.numBones {
            let pos = latestPositionsSnapshot[i]
            if pos.x.isNaN || pos.y.isNaN || pos.z.isNaN || pos.x.isInfinite || pos.y.isInfinite
                || pos.z.isInfinite {
                // Replace with zero - writeBonesToNodes will skip this bone
                latestPositionsSnapshot[i] = SIMD3<Float>(repeating: Float.nan)
                nanCount += 1
            }
        }
        latestCompletedFrame = frameID
        snapshotLock.unlock()
    }

    private func updateNodeTransformsForChain(
        nodePositions: [(VRMNode, SIMD3<Float>, Int)],
        maxSwingAngle: Float? = nil
    ) {
        // Update bone rotations to point toward physics-simulated positions
        for i in 0..<nodePositions.count - 1 {
            let (currentNode, currentPos, globalIndex) = nodePositions[i]
            let (_, nextPos, _) = nodePositions[i + 1]

            // NaN guard: skip if positions are invalid
            if currentPos.x.isNaN || currentPos.y.isNaN || currentPos.z.isNaN || nextPos.x.isNaN
                || nextPos.y.isNaN || nextPos.z.isNaN {
                continue
            }

            // Calculate direction vector from current bone to next bone
            let toNext = nextPos - currentPos
            let distance = length(toNext)

            if distance < 0.001 { continue }

            let targetDir = toNext / distance

            // VRM SpringBone Rotation Update (per three-vrm spec):
            // Use setFromUnitVectors(initialAxis, newLocalDirection) where BOTH are in bone's local space.
            // This computes ABSOLUTE rotation, not accumulated delta.

            // Get bind direction stored in PARENT's local space (at bind time)
            guard globalIndex < boneBindDirections.count else { continue }
            let bindDirInParentSpace = boneBindDirections[globalIndex]

            // NaN guard: skip if bind direction is invalid
            if bindDirInParentSpace.x.isNaN || bindDirInParentSpace.y.isNaN
                || bindDirInParentSpace.z.isNaN || simd_length(bindDirInParentSpace) < 0.001 {
                continue
            }

            // Get parent's world rotation (CURRENT, after earlier bones in chain were updated)
            guard let parent = currentNode.parent else { continue }
            let parentRot = extractRotation(from: parent.worldMatrix)

            // NaN guard for parent rotation
            if parentRot.real.isNaN || parentRot.imag.x.isNaN || parentRot.imag.y.isNaN
                || parentRot.imag.z.isNaN {
                currentNode.localRotation = currentNode.initialRotation
                currentNode.updateLocalMatrix()
                currentNode.updateWorldTransform()
                continue
            }

            // Per three-vrm spec: compute swing rotation and apply ON TOP of initial rotation.
            // This preserves the bone's original twist/roll from bind pose.
            //
            // Step 1: Transform target direction to parent's local space
            let parentRotInv = simd_conjugate(parentRot)
            let targetDirParent = simd_act(parentRotInv, targetDir)

            // Step 2: Transform target direction to bone's REST frame (bind pose local space)
            // This tells us "where is the target relative to the bone's original orientation"
            let initialRotInv = simd_conjugate(currentNode.initialRotation)
            let targetDirRest = simd_act(initialRotInv, targetDirParent)

            // Step 3: Get bone's initial forward axis in its local space
            let initialAxis = simd_act(initialRotInv, bindDirInParentSpace)

            // Step 4: Calculate "swing" rotation needed to align initial axis with target
            //
            // SOFT DEADZONE: Instead of hard cutoff, smoothly blend physics influence.
            // - Deadzone: 0.001 (1mm) - below this, use initial rotation (sleep)
            // - Fade range: 0.005 (5mm) - smooth transition to full physics
            // This prevents both flutter (at rest) and popping (during transition)
            //
            // For unit vectors: distance ≈ 2*sin(θ/2) ≈ θ for small angles
            let initialAxisNorm = simd_normalize(initialAxis)
            let targetDirNorm = simd_normalize(targetDirRest)
            let displacement = simd_length(targetDirNorm - initialAxisNorm)

            let deadzone: Float = 0.001  // 1mm - sleep threshold
            let fadeRange: Float = 0.005  // 5mm - smooth transition range

            // Calculate blend weight: 0 at deadzone, 1 at deadzone+fadeRange
            let physicsWeight = min(max((displacement - deadzone) / fadeRange, 0.0), 1.0)

            var newRotation: simd_quatf
            let dotProduct = simd_dot(initialAxisNorm, targetDirNorm)

            if dotProduct > 0.9998 {  // ~1.15 degrees - numerical stability zone
                // Nearly parallel - use initial rotation to prevent swirl
                newRotation = currentNode.initialRotation
            } else {
                // Compute swing rotation and apply ON TOP of initial rotation
                let swingRotation = quaternionFromTo(from: initialAxis, to: targetDirRest)
                let physicsRotation = currentNode.initialRotation * swingRotation

                // Soft blend: slerp between initial (rest) and physics rotation
                if physicsWeight < 0.001 {
                    // In deadzone - sleep
                    newRotation = currentNode.initialRotation
                } else if physicsWeight > 0.999 {
                    // Full physics
                    newRotation = physicsRotation
                } else {
                    // Blend zone - smooth transition
                    newRotation = simd_slerp(
                        currentNode.initialRotation, physicsRotation, physicsWeight)
                }
            }

            // NaN guard: skip if rotation is invalid
            if newRotation.real.isNaN || newRotation.imag.x.isNaN || newRotation.imag.y.isNaN
                || newRotation.imag.z.isNaN {
                continue
            }

            // Final NaN/Inf guard before applying - reset to bind pose if calculation produced bad values
            // IMPORTANT: Check both isNaN AND isInfinite - Inf quaternions produce NaN matrices
            if newRotation.real.isNaN || newRotation.real.isInfinite || newRotation.imag.x.isNaN
                || newRotation.imag.x.isInfinite || newRotation.imag.y.isNaN
                || newRotation.imag.y.isInfinite || newRotation.imag.z.isNaN
                || newRotation.imag.z.isInfinite {
                currentNode.localRotation = currentNode.initialRotation
                currentNode.updateLocalMatrix()
                currentNode.updateWorldTransform()
                continue
            }

            // Clamp swing magnitude for breast chains — prevents mesh deformation artifact
            if let maxAngle = maxSwingAngle, maxAngle > 0 {
                let delta = simd_mul(simd_conjugate(currentNode.initialRotation), newRotation)
                let halfAngle = acos(min(abs(delta.real), 1.0))
                if halfAngle > maxAngle * 0.5 {
                    let t = (maxAngle * 0.5) / halfAngle
                    newRotation = simd_slerp(currentNode.initialRotation, newRotation, t)
                }
            }

            currentNode.localRotation = newRotation
            currentNode.updateLocalMatrix()
            currentNode.updateWorldTransform()
        }
    }

    private func quaternionFromTo(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        // THREE.JS HALF-ANGLE FORMULATION (numerically stable)
        // Based on three.js Quaternion.setFromUnitVectors
        //
        // Why this is better than angle-axis:
        // 1. No acos() call - acos loses precision near 1.0, causing noise for small angles
        // 2. For small angles, w ≈ 2 and xyz ≈ 0, giving clean near-identity quaternions
        // 3. Cross product magnitude naturally scales with sin(θ), no separate axis normalization
        //
        // Formula: q = (cross(a,b), 1 + dot(a,b)).normalize()
        // This exploits the half-angle identity: q = (sin(θ/2)*axis, cos(θ/2))
        // where 1 + dot(a,b) = 1 + cos(θ) = 2*cos²(θ/2) ∝ cos(θ/2) after normalization

        // Input validation
        let fromLen = simd_length(from)
        let toLen = simd_length(to)
        if fromLen < 0.0001 || toLen < 0.0001 || fromLen.isNaN || fromLen.isInfinite || toLen.isNaN
            || toLen.isInfinite {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        // Normalize inputs
        let vFrom = from / fromLen
        let vTo = to / toLen

        // r = 1 + dot(vFrom, vTo)
        var r = simd_dot(vFrom, vTo) + 1.0

        if r < 0.000001 {
            // Nearly anti-parallel (180° rotation)
            // Find perpendicular axis
            r = 0
            var qx: Float
            var qy: Float
            var qz: Float

            if abs(vFrom.x) > abs(vFrom.z) {
                // Perpendicular in XY plane
                qx = -vFrom.y
                qy = vFrom.x
                qz = 0
            } else {
                // Perpendicular in YZ plane
                qx = 0
                qy = -vFrom.z
                qz = vFrom.y
            }

            let q = simd_quatf(ix: qx, iy: qy, iz: qz, r: r)
            return simd_normalize(q)
        }

        // Cross product gives axis * sin(θ), r gives 1 + cos(θ)
        let crossVec = simd_cross(vFrom, vTo)
        let q = simd_quatf(ix: crossVec.x, iy: crossVec.y, iz: crossVec.z, r: r)
        return simd_normalize(q)
    }

    func extractRotation(from matrix: float4x4) -> simd_quatf {
        let rotationMatrix = float3x3(
            SIMD3<Float>(matrix[0][0], matrix[0][1], matrix[0][2]),
            SIMD3<Float>(matrix[1][0], matrix[1][1], matrix[1][2]),
            SIMD3<Float>(matrix[2][0], matrix[2][1], matrix[2][2])
        )
        return simd_quatf(rotationMatrix)
    }
}
