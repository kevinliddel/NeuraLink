//
//  VRMGeometry+Node.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

// MARK: - VRM Node

public class VRMNode {
    public let index: Int
    public let name: String?
    public weak var parent: VRMNode?
    public var children: [VRMNode] = []

    // Transform components
    public var translation: SIMD3<Float> = [0, 0, 0]
    public var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    public var scale: SIMD3<Float> = [1, 1, 1]

    // Initial Bind Pose (for resetting or procedural animation reference)
    public let initialTranslation: SIMD3<Float>
    public let initialRotation: simd_quatf
    public let initialScale: SIMD3<Float>

    // Computed transforms
    public var localMatrix: float4x4 = matrix_identity_float4x4
    public var worldMatrix: float4x4 = matrix_identity_float4x4

    // Computed properties for SpringBone
    public var worldPosition: SIMD3<Float> {
        return SIMD3<Float>(worldMatrix[3][0], worldMatrix[3][1], worldMatrix[3][2])
    }

    public var localRotation: simd_quatf {
        get { return rotation }
        set {
            rotation = newValue
            updateLocalMatrix()
        }
    }

    // References
    public var mesh: Int?
    public var skin: Int?

    public init(index: Int, gltfNode: GLTFNode) {
        self.index = index
        self.name = gltfNode.name
        self.mesh = gltfNode.mesh
        self.skin = gltfNode.skin

        // Parse transform
        if let matrix = gltfNode.matrix, matrix.count == 16 {
            // GLTF matrices are stored in column-major order: indices 0-3 = column 0, 4-7 = column 1, etc.
            // float4x4 initializer takes columns, so we pass each column directly
            let m = float4x4(
                SIMD4<Float>(matrix[0], matrix[1], matrix[2], matrix[3]),  // column 0
                SIMD4<Float>(matrix[4], matrix[5], matrix[6], matrix[7]),  // column 1
                SIMD4<Float>(matrix[8], matrix[9], matrix[10], matrix[11]),  // column 2
                SIMD4<Float>(matrix[12], matrix[13], matrix[14], matrix[15])  // column 3 (translation)
            )

            // Decompose matrix to get T/R/S
            // This ensures that even if initialized with a matrix, we have valid T/R/S components
            // for the animation system to work with.
            let decomp = decomposeMatrix(m)
            self.translation = decomp.translation
            self.rotation = decomp.rotation
            self.scale = decomp.scale
        } else {
            if let t = gltfNode.translation, t.count == 3 {
                translation = SIMD3<Float>(t[0], t[1], t[2])
            }
            if let r = gltfNode.rotation, r.count == 4 {
                rotation = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            }
            if let s = gltfNode.scale, s.count == 3 {
                scale = SIMD3<Float>(s[0], s[1], s[2])
            }
        }

        // Store initial values as bind pose
        self.initialTranslation = translation
        self.initialRotation = rotation
        self.initialScale = scale

        // Update local matrix from T/R/S
        updateLocalMatrix()
    }

    /// Reset node transform to its initial bind pose (as defined in the file)
    public func resetToBindPose() {
        translation = initialTranslation
        rotation = initialRotation
        scale = initialScale
        updateLocalMatrix()
    }

    public func updateLocalMatrix() {
        let t = float4x4(translation: translation)

        // Manual quaternion to matrix conversion (Column-Major)
        let x = rotation.imag.x
        let y = rotation.imag.y
        let z = rotation.imag.z
        let w = rotation.real

        let xx = x * x
        let yy = y * y
        let zz = z * z
        let xy = x * y
        let xz = x * z
        let yz = y * z
        let wx = w * x
        let wy = w * y
        let wz = w * z

        let col0 = SIMD4<Float>(1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz), 2.0 * (xz - wy), 0.0)
        let col1 = SIMD4<Float>(2.0 * (xy - wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx), 0.0)
        let col2 = SIMD4<Float>(2.0 * (xz + wy), 2.0 * (yz - wx), 1.0 - 2.0 * (xx + yy), 0.0)
        let col3 = SIMD4<Float>(0.0, 0.0, 0.0, 1.0)

        let r = float4x4([col0, col1, col2, col3])

        let s = float4x4(scaling: scale)
        localMatrix = t * r * s
    }

    public func updateWorldTransform() {
        // Check for NaNs before using localMatrix
        if localMatrix[0][0].isNaN || localMatrix[0][1].isNaN || localMatrix[0][2].isNaN
            || localMatrix[0][3].isNaN || localMatrix[1][0].isNaN || localMatrix[1][1].isNaN
            || localMatrix[1][2].isNaN || localMatrix[1][3].isNaN || localMatrix[2][0].isNaN
            || localMatrix[2][1].isNaN || localMatrix[2][2].isNaN || localMatrix[2][3].isNaN
            || localMatrix[3][0].isNaN || localMatrix[3][1].isNaN || localMatrix[3][2].isNaN
            || localMatrix[3][3].isNaN
        {
            // Reset localMatrix to identity to prevent crash
            localMatrix = matrix_identity_float4x4
        }

        if let parent = parent {
            worldMatrix = parent.worldMatrix * localMatrix
        } else {
            worldMatrix = localMatrix
        }

        for child in children {
            child.updateWorldTransform()
        }
    }
}

// MARK: - Matrix Decomposition

private func decomposeMatrix(_ matrix: float4x4) -> (
    translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>
) {
    let translation = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)

    var column0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
    var column1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
    var column2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)

    var scaleX = length(column0)
    var scaleY = length(column1)
    var scaleZ = length(column2)

    if scaleX > 1e-6 { column0 /= scaleX } else { scaleX = 1 }
    if scaleY > 1e-6 { column1 /= scaleY } else { scaleY = 1 }
    if scaleZ > 1e-6 { column2 /= scaleZ } else { scaleZ = 1 }

    var rotationMatrix = float3x3(columns: (column0, column1, column2))

    if simd_determinant(rotationMatrix) < 0 {
        scaleX = -scaleX
        rotationMatrix.columns.0 = -rotationMatrix.columns.0
    }

    let rotation = simd_quatf(rotationMatrix)
    let scale = SIMD3<Float>(scaleX, scaleY, scaleZ)

    return (translation, rotation, scale)
}
