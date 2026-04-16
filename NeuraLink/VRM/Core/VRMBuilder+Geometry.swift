//
// VRMBuilder+Geometry.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - Humanoid Geometry Generation

extension VRMBuilder {

    struct MeshData {
        let positions: [Float]
        let normals: [Float]
        let texcoords: [Float]
        let indices: [UInt16]
    }

    func generateHumanoidGeometry() -> MeshData {
        // Generate a basic humanoid body mesh using parametric modeling
        let height = morphValues["height"] ?? 1.0
        let muscleDefinition = morphValues["muscle_definition"] ?? 1.0
        let shoulderWidth = morphValues["shoulder_width"] ?? 1.0

        // Basic human body parameters (simplified)
        let bodyHeight: Float = 1.8 * height
        let headRadius: Float = 0.12
        let neckRadius: Float = 0.08
        let chestRadius: Float = 0.18 * muscleDefinition
        let waistRadius: Float = 0.12
        let hipRadius: Float = 0.15

        // Generate a simple humanoid using connected spheres and cylinders
        var positions: [Float] = []
        var normals: [Float] = []
        var texcoords: [Float] = []
        var indices: [UInt16] = []

        let segments = 16
        let rings = 8
        var vertexIndex: UInt16 = 0

        // Helper function to add a sphere
        func addSphere(center: SIMD3<Float>, radius: Float, segments: Int, rings: Int) {
            for i in 0...rings {
                let phi = Float.pi * Float(i) / Float(rings)
                for j in 0..<segments {
                    let theta = 2 * Float.pi * Float(j) / Float(segments)

                    let x = center.x + radius * sin(phi) * cos(theta)
                    let y = center.y + radius * cos(phi)
                    let z = center.z + radius * sin(phi) * sin(theta)

                    positions.append(x)
                    positions.append(y)
                    positions.append(z)

                    // Normal (for sphere, normalized position - center)
                    let nx = (x - center.x) / radius
                    let ny = (y - center.y) / radius
                    let nz = (z - center.z) / radius
                    normals.append(nx)
                    normals.append(ny)
                    normals.append(nz)

                    // UV coordinates
                    let u = Float(j) / Float(segments)
                    let v = Float(i) / Float(rings)
                    texcoords.append(u)
                    texcoords.append(v)
                }
            }

            // Add indices for triangles
            for i in 0..<rings {
                for j in 0..<segments {
                    let current = vertexIndex + UInt16(i * segments + j)
                    let next = vertexIndex + UInt16(((i + 1) % (rings + 1)) * segments + j)
                    let nextJ = vertexIndex + UInt16(i * segments + ((j + 1) % segments))
                    let nextNextJ =
                        vertexIndex
                        + UInt16(((i + 1) % (rings + 1)) * segments + ((j + 1) % segments))

                    // Two triangles per quad
                    indices.append(contentsOf: [current, next, nextJ])
                    indices.append(contentsOf: [nextJ, next, nextNextJ])
                }
            }

            vertexIndex += UInt16((rings + 1) * segments)
        }

        // Generate body parts as connected spheres
        // TORSO
        // Head
        addSphere(
            center: SIMD3<Float>(0, bodyHeight - headRadius, 0), radius: headRadius,
            segments: segments, rings: rings)

        // Neck
        addSphere(
            center: SIMD3<Float>(0, bodyHeight - headRadius - 0.15, 0), radius: neckRadius,
            segments: segments / 2, rings: rings / 2)

        // Chest
        addSphere(
            center: SIMD3<Float>(0, bodyHeight - headRadius - 0.4, 0), radius: chestRadius,
            segments: segments, rings: rings)

        // Waist
        addSphere(
            center: SIMD3<Float>(0, bodyHeight - headRadius - 0.7, 0), radius: waistRadius,
            segments: segments, rings: rings)

        // Hips
        addSphere(
            center: SIMD3<Float>(0, bodyHeight - headRadius - 0.9, 0), radius: hipRadius,
            segments: segments, rings: rings)

        // ARMS
        let armRadius: Float = 0.05 * muscleDefinition
        let shoulderY = bodyHeight - headRadius - 0.4
        let shoulderX: Float = 0.15 * shoulderWidth

        // Left arm
        addSphere(
            center: SIMD3<Float>(shoulderX, shoulderY, 0), radius: armRadius * 1.1,
            segments: segments / 2, rings: rings / 2)  // Shoulder
        addSphere(
            center: SIMD3<Float>(shoulderX + 0.13, shoulderY - 0.05, 0), radius: armRadius,
            segments: segments / 2, rings: rings / 2)  // Upper arm mid
        addSphere(
            center: SIMD3<Float>(shoulderX + 0.25, shoulderY - 0.1, 0), radius: armRadius * 0.8,
            segments: segments / 2, rings: rings / 2)  // Elbow
        addSphere(
            center: SIMD3<Float>(shoulderX + 0.38, shoulderY - 0.15, 0), radius: armRadius * 0.7,
            segments: segments / 2, rings: rings / 2)  // Lower arm mid
        addSphere(
            center: SIMD3<Float>(shoulderX + 0.5, shoulderY - 0.2, 0), radius: armRadius * 0.6,
            segments: segments / 2, rings: rings / 2)  // Hand

        // Right arm
        addSphere(
            center: SIMD3<Float>(-shoulderX, shoulderY, 0), radius: armRadius * 1.1,
            segments: segments / 2, rings: rings / 2)  // Shoulder
        addSphere(
            center: SIMD3<Float>(-shoulderX - 0.13, shoulderY - 0.05, 0), radius: armRadius,
            segments: segments / 2, rings: rings / 2)  // Upper arm mid
        addSphere(
            center: SIMD3<Float>(-shoulderX - 0.25, shoulderY - 0.1, 0), radius: armRadius * 0.8,
            segments: segments / 2, rings: rings / 2)  // Elbow
        addSphere(
            center: SIMD3<Float>(-shoulderX - 0.38, shoulderY - 0.15, 0), radius: armRadius * 0.7,
            segments: segments / 2, rings: rings / 2)  // Lower arm mid
        addSphere(
            center: SIMD3<Float>(-shoulderX - 0.5, shoulderY - 0.2, 0), radius: armRadius * 0.6,
            segments: segments / 2, rings: rings / 2)  // Hand

        // LEGS
        let legRadius: Float = 0.08 * muscleDefinition
        let hipY = bodyHeight - headRadius - 0.95
        let hipX: Float = 0.1

        // Left leg
        addSphere(
            center: SIMD3<Float>(hipX, hipY, 0), radius: legRadius * 1.2, segments: segments / 2,
            rings: rings / 2)  // Upper thigh
        addSphere(
            center: SIMD3<Float>(hipX, hipY - 0.23, 0), radius: legRadius, segments: segments / 2,
            rings: rings / 2)  // Mid thigh
        addSphere(
            center: SIMD3<Float>(hipX, hipY - 0.45, 0), radius: legRadius * 0.9,
            segments: segments / 2, rings: rings / 2)  // Knee
        addSphere(
            center: SIMD3<Float>(hipX, hipY - 0.68, 0), radius: legRadius * 0.7,
            segments: segments / 2, rings: rings / 2)  // Mid shin
        addSphere(
            center: SIMD3<Float>(hipX, hipY - 0.9, 0), radius: legRadius * 0.8,
            segments: segments / 2, rings: rings / 2)  // Ankle
        addSphere(
            center: SIMD3<Float>(hipX, hipY - 0.95, 0.05), radius: legRadius * 0.6,
            segments: segments / 2, rings: rings / 2)  // Foot

        // Right leg
        addSphere(
            center: SIMD3<Float>(-hipX, hipY, 0), radius: legRadius * 1.2, segments: segments / 2,
            rings: rings / 2)  // Upper thigh
        addSphere(
            center: SIMD3<Float>(-hipX, hipY - 0.23, 0), radius: legRadius, segments: segments / 2,
            rings: rings / 2)  // Mid thigh
        addSphere(
            center: SIMD3<Float>(-hipX, hipY - 0.45, 0), radius: legRadius * 0.9,
            segments: segments / 2, rings: rings / 2)  // Knee
        addSphere(
            center: SIMD3<Float>(-hipX, hipY - 0.68, 0), radius: legRadius * 0.7,
            segments: segments / 2, rings: rings / 2)  // Mid shin
        addSphere(
            center: SIMD3<Float>(-hipX, hipY - 0.9, 0), radius: legRadius * 0.8,
            segments: segments / 2, rings: rings / 2)  // Ankle
        addSphere(
            center: SIMD3<Float>(-hipX, hipY - 0.95, 0.05), radius: legRadius * 0.6,
            segments: segments / 2, rings: rings / 2)  // Foot

        return MeshData(
            positions: positions,
            normals: normals,
            texcoords: texcoords,
            indices: indices
        )
    }
}
