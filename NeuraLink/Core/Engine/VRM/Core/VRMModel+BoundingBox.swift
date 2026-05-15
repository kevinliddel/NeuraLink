//
// VRMModel+BoundingBox.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import Metal
import simd

extension VRMModel {

    // MARK: - Bounding Box Calculation

    /// Calculate axis-aligned bounding box from all mesh vertices in model space
    public func calculateBoundingBox(includeAnimated: Bool = false) -> (
        min: SIMD3<Float>, max: SIMD3<Float>
    ) {
        var minBounds = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBounds = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)
        var foundAnyVertex = false

        // Iterate through all meshes and primitives
        for (meshIndex, mesh) in meshes.enumerated() {
            for primitive in mesh.primitives {
                // Try to read vertex positions from the Metal buffer
                guard let vertexBuffer = primitive.vertexBuffer,
                    primitive.vertexCount > 0
                else {
                    continue
                }

                // Map the buffer to read vertex data
                let bufferPointer = vertexBuffer.contents().bindMemory(
                    to: VRMVertex.self, capacity: primitive.vertexCount)

                // Apply world transform if requested
                let worldTransform: float4x4
                if includeAnimated {
                    // Find the node that references this mesh
                    if let nodeIndex = nodes.firstIndex(where: { $0.mesh == meshIndex }) {
                        worldTransform = nodes[nodeIndex].worldMatrix
                    } else {
                        worldTransform = matrix_identity_float4x4
                    }
                } else {
                    worldTransform = matrix_identity_float4x4
                }

                // Process each vertex
                for vertexIndex in 0..<primitive.vertexCount {
                    let vertex = bufferPointer[vertexIndex]
                    var position = vertex.position

                    // Apply transform if not identity
                    if includeAnimated {
                        let position4 =
                            worldTransform * SIMD4<Float>(position.x, position.y, position.z, 1.0)
                        position = SIMD3<Float>(position4.x, position4.y, position4.z)
                    }

                    minBounds = min(minBounds, position)
                    maxBounds = max(maxBounds, position)
                    foundAnyVertex = true
                }
            }
        }

        // Fallback to reasonable defaults if no vertices found
        if !foundAnyVertex {
            minBounds = SIMD3<Float>(-0.5, 0, -0.5)
            maxBounds = SIMD3<Float>(0.5, 1.8, 0.5)  // ~1.8m tall
        }

        return (minBounds, maxBounds)
    }

    public func calculateSkinnedBoundingBox() -> (
        min: SIMD3<Float>, max: SIMD3<Float>, center: SIMD3<Float>, size: SIMD3<Float>
    ) {
        // For skinned models, estimate from the skeleton
        var minBounds = SIMD3<Float>(Float.infinity, Float.infinity, Float.infinity)
        var maxBounds = SIMD3<Float>(-Float.infinity, -Float.infinity, -Float.infinity)

        // Use joint positions after skinning
        for node in nodes {
            let worldPos = SIMD3<Float>(
                node.worldMatrix[3][0],
                node.worldMatrix[3][1],
                node.worldMatrix[3][2]
            )

            // Add some padding around each joint
            let padding: Float = 0.1
            minBounds = min(minBounds, worldPos - padding)
            maxBounds = max(maxBounds, worldPos + padding)
        }

        // If we have a humanoid, use key bones to estimate bounds
        if let humanoid = humanoid {
            // Get hips position as center reference
            if let hipsIndex = humanoid.getBoneNode(.hips),
                hipsIndex < nodes.count {
                // Get head for height
                if let headIndex = humanoid.getBoneNode(.head),
                    headIndex < nodes.count {
                    let headNode = nodes[headIndex]
                    let headPos = SIMD3<Float>(
                        headNode.worldMatrix[3][0],
                        headNode.worldMatrix[3][1],
                        headNode.worldMatrix[3][2]
                    )
                    maxBounds = max(maxBounds, headPos + SIMD3<Float>(0.2, 0.2, 0.2))  // Add head padding
                }

                // Get feet for bottom
                if let leftFootIndex = humanoid.getBoneNode(.leftFoot),
                    leftFootIndex < nodes.count {
                    let footNode = nodes[leftFootIndex]
                    let footPos = SIMD3<Float>(
                        footNode.worldMatrix[3][0],
                        footNode.worldMatrix[3][1],
                        footNode.worldMatrix[3][2]
                    )
                    minBounds = min(minBounds, footPos - SIMD3<Float>(0.1, 0.1, 0.1))
                }
            }
        }

        // Fallback to reasonable defaults if bounds are invalid
        if minBounds.x == Float.infinity {
            minBounds = SIMD3<Float>(-0.5, 0, -0.5)
            maxBounds = SIMD3<Float>(0.5, 1.8, 0.5)  // ~1.8m tall
        }

        let center = (minBounds + maxBounds) * 0.5
        let size = maxBounds - minBounds

        return (minBounds, maxBounds, center, size)
    }
}
