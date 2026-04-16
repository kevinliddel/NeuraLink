//
// SpringBoneSkinningSystem.swift
// NeuraLink
//
// Created by Dedicatus on 16/04/2026.
//

import Metal
import simd

final class SpringBoneSkinningSystem {
    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
    }

    func updateJointMatrices(model: VRMModel) {
        guard let buffers = model.springBoneBuffers,
            let springBone = model.springBone,
            buffers.numBones > 0
        else {
            return
        }

        let currentPositions = buffers.getCurrentPositions()
        var boneIndex = 0

        // Process each spring chain
        for spring in springBone.springs {
            var chainPositions: [SIMD3<Float>] = []
            var chainNodes: [VRMNode] = []

            // Collect positions and nodes for this chain
            for joint in spring.joints {
                if let node = model.nodes[safe: joint.node] {
                    chainPositions.append(currentPositions[boneIndex])
                    chainNodes.append(node)
                    boneIndex += 1
                }
            }

            // Update joint matrices for this chain
            updateChainJointMatrices(positions: chainPositions, nodes: chainNodes, model: model)
        }
    }

    private func updateChainJointMatrices(
        positions: [SIMD3<Float>], nodes: [VRMNode], model: VRMModel
    ) {
        guard positions.count == nodes.count, positions.count >= 2 else {
            return
        }

        // Update root bone (first in chain)
        let rootPosition = positions[0]
        let rootNode = nodes[0]
        rootNode.translation = rootPosition
        rootNode.updateWorldTransform()

        // Update child bones with proper orientation
        for i in 1..<positions.count {
            let currentPos = positions[i]
            let parentPos = positions[i - 1]
            let currentNode = nodes[i]
            let parentNode = nodes[i - 1]

            // Calculate direction vector
            let direction = simd_normalize(currentPos - parentPos)

            // Reconstruct rotation using swing-twist decomposition
            let rotation = calculateBoneRotation(
                currentDirection: direction,
                parentNode: parentNode,
                currentNode: currentNode
            )

            // Update node transforms
            currentNode.translation = parentNode.worldPosition
            currentNode.localRotation = rotation
            currentNode.updateWorldTransform()
        }

        // Note: Skin joint matrix updates are handled by the main VRMSkinningSystem
        // The node transforms have been updated, so the skinning system will use them
    }

    private func calculateBoneRotation(
        currentDirection: SIMD3<Float>, parentNode: VRMNode, currentNode: VRMNode
    ) -> simd_quatf {
        // Get the rest direction (bind pose direction)
        let restDirection = simd_normalize(currentNode.worldPosition - parentNode.worldPosition)

        // Calculate swing rotation to align rest direction to current direction
        let swingRotation = simd_quatf(from: restDirection, to: currentDirection)

        // Preserve the original twist around the bone axis
        let boneAxis = simd_normalize(restDirection)
        let originalRotation = currentNode.localRotation

        // Extract twist component from original rotation
        let twistRotation = extractTwist(rotation: originalRotation, axis: boneAxis)

        // Combine swing and twist
        return swingRotation * twistRotation
    }

    private func extractTwist(rotation: simd_quatf, axis: SIMD3<Float>) -> simd_quatf {
        // Project quaternion onto axis to get twist component
        let dotProduct = simd_dot(rotation.vector, SIMD4<Float>(axis.x, axis.y, axis.z, 0))
        let twistVector = SIMD4<Float>(
            axis.x * dotProduct, axis.y * dotProduct, axis.z * dotProduct, rotation.vector.w)

        let length = simd_length(twistVector)
        if length > 0 {
            return simd_quatf(vector: twistVector / length)
        }
        return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    func debugVisualizeSpringBones(model: VRMModel, renderer: VRMRenderer) {
        guard let buffers = model.springBoneBuffers,
            let springBone = model.springBone,
            buffers.numBones > 0
        else {
            return
        }

        let currentPositions = buffers.getCurrentPositions()
        var boneIndex = 0

        // Draw debug lines for each spring chain
        for spring in springBone.springs {
            var chainPositions: [SIMD3<Float>] = []

            for _ in spring.joints {
                chainPositions.append(currentPositions[boneIndex])
                boneIndex += 1
            }

            // Draw chain as connected line segments
            drawDebugChain(positions: chainPositions, color: SIMD4<Float>(1, 0, 0, 1))

            // Draw bone endpoints
            for position in chainPositions {
                drawDebugSphere(center: position, radius: 0.01, color: SIMD4<Float>(0, 1, 0, 1))
            }
        }

        // Draw colliders
        if let sphereColliders = buffers.sphereColliders {
            let colliders = Array(
                UnsafeBufferPointer(
                    start: sphereColliders.contents().bindMemory(
                        to: SphereCollider.self, capacity: buffers.numSpheres),
                    count: buffers.numSpheres
                ))

            for collider in colliders {
                drawDebugSphere(
                    center: collider.center, radius: collider.radius,
                    color: SIMD4<Float>(0, 0, 1, 0.3))
            }
        }

        if let capsuleColliders = buffers.capsuleColliders {
            let colliders = Array(
                UnsafeBufferPointer(
                    start: capsuleColliders.contents().bindMemory(
                        to: CapsuleCollider.self, capacity: buffers.numCapsules),
                    count: buffers.numCapsules
                ))

            for collider in colliders {
                drawDebugCapsule(
                    p0: collider.p0, p1: collider.p1, radius: collider.radius,
                    color: SIMD4<Float>(0, 0, 1, 0.3))
            }
        }
    }

    private func drawDebugChain(positions: [SIMD3<Float>], color: SIMD4<Float>) {
        // Implementation depends on your debug rendering system
        // This would typically use immediate mode line drawing
        for i in 0..<positions.count - 1 {
            _ = positions[i]  // start
            _ = positions[i + 1]  // end
            // renderer.drawDebugLine(from: positions[i], to: positions[i + 1], color: color)
        }
    }

    private func drawDebugSphere(center: SIMD3<Float>, radius: Float, color: SIMD4<Float>) {
        // Implementation depends on your debug rendering system
        // renderer.drawDebugSphere(center: center, radius: radius, color: color)
    }

    private func drawDebugCapsule(
        p0: SIMD3<Float>, p1: SIMD3<Float>, radius: Float, color: SIMD4<Float>
    ) {
        // Implementation depends on your debug rendering system
        // renderer.drawDebugCapsule(p0: p0, p1: p1, radius: radius, color: color)
    }
}
