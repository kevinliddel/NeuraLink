//
//  VRMUniforms.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import simd

/// Uniform data structure for VRM rendering shaders.
/// Metal requires 16-byte alignment for all struct members.
struct Uniforms {
    // Transform matrices (64 bytes each)
    var modelMatrix = matrix_identity_float4x4  // 64 bytes, offset 0
    var viewMatrix = matrix_identity_float4x4  // 64 bytes, offset 64
    var projectionMatrix = matrix_identity_float4x4  // 64 bytes, offset 128
    var normalMatrix = matrix_identity_float4x4  // 64 bytes, offset 192

    // Light 0 (key light) - Balanced lighting for VRM 0.0 and 1.0
    // Compromise: front-dominant with moderate top component
    // After shader negation (-lightDir), effective direction is (0.25, 0.5, 0.83)
    // This provides front lighting for VRM 1.0 while not breaking VRM 0.0 eyebrows
    var lightDirection_packed = SIMD4<Float>(-0.25, -0.5, -0.83, 0.0)  // 16 bytes, offset 256 (xyz = direction)
    var lightColor_packed = SIMD4<Float>(1.0, 1.0, 1.0, 1.732)  // 16 bytes, offset 272 (xyz = color, w = intensity)
    var ambientColor_packed = SIMD4<Float>(0.05, 0.05, 0.05, 0.0)  // 16 bytes, offset 288 (SIMD3 + padding)

    // Light 1 (fill light)
    var light1Direction_packed = SIMD4<Float>(0, 0, 0, 0)  // 16 bytes, offset 304 (xyz = direction)
    var light1Color_packed = SIMD4<Float>(0, 0, 0, 0)  // 16 bytes, offset 320 (xyz = color, w = intensity)

    // Light 2 (rim/back light)
    var light2Direction_packed = SIMD4<Float>(0, 0, 0, 0)  // 16 bytes, offset 336 (xyz = direction)
    var light2Color_packed = SIMD4<Float>(0, 0, 0, 0)  // 16 bytes, offset 352 (xyz = color, w = intensity)

    // Other fields
    var viewportSize_packed = SIMD4<Float>(1280, 720, 0.0, 0.0)  // 16 bytes, offset 368 (SIMD2 + padding)
    var nearPlane_packed = SIMD4<Float>(0.1, 100.0, 0.0, 0.0)  // 16 bytes, offset 384 (2 floats + padding)
    var debugUVs: Int32 = 0  // 4 bytes, offset 400
    var lightNormalizationFactor: Float = 1.0  // 4 bytes, offset 404
    var _padding2: Float = 0  // 4 bytes padding
    var _padding3: Float = 0  // 4 bytes padding to align to 16 bytes
    var toonBands: Int32 = 3  // 4 bytes, offset 416
    var _padding5: Float = 0  // 4 bytes padding
    var _padding6: Float = 0  // 4 bytes padding
    var _padding7: Float = 0  // 4 bytes padding to align to 16 bytes
    // Total: 432 bytes (27 x 16-byte blocks)

    // Computed properties for easy access
    var lightDirection: SIMD3<Float> {
        get {
            SIMD3<Float>(lightDirection_packed.x, lightDirection_packed.y, lightDirection_packed.z)
        }
        set { lightDirection_packed = SIMD4<Float>(newValue.x, newValue.y, newValue.z, 0.0) }
    }

    var lightColor: SIMD3<Float> {
        get { SIMD3<Float>(lightColor_packed.x, lightColor_packed.y, lightColor_packed.z) }
        set {
            lightColor_packed = SIMD4<Float>(
                newValue.x, newValue.y, newValue.z, simd_length(newValue))
        }
    }

    var ambientColor: SIMD3<Float> {
        get { SIMD3<Float>(ambientColor_packed.x, ambientColor_packed.y, ambientColor_packed.z) }
        set { ambientColor_packed = SIMD4<Float>(newValue.x, newValue.y, newValue.z, 0.0) }
    }

    var light1Direction: SIMD3<Float> {
        get {
            SIMD3<Float>(
                light1Direction_packed.x, light1Direction_packed.y, light1Direction_packed.z)
        }
        set { light1Direction_packed = SIMD4<Float>(newValue.x, newValue.y, newValue.z, 0.0) }
    }

    var light1Color: SIMD3<Float> {
        get { SIMD3<Float>(light1Color_packed.x, light1Color_packed.y, light1Color_packed.z) }
        set {
            light1Color_packed = SIMD4<Float>(
                newValue.x, newValue.y, newValue.z, simd_length(newValue))
        }
    }

    var light2Direction: SIMD3<Float> {
        get {
            SIMD3<Float>(
                light2Direction_packed.x, light2Direction_packed.y, light2Direction_packed.z)
        }
        set { light2Direction_packed = SIMD4<Float>(newValue.x, newValue.y, newValue.z, 0.0) }
    }

    var light2Color: SIMD3<Float> {
        get { SIMD3<Float>(light2Color_packed.x, light2Color_packed.y, light2Color_packed.z) }
        set {
            light2Color_packed = SIMD4<Float>(
                newValue.x, newValue.y, newValue.z, simd_length(newValue))
        }
    }

    var viewportSize: SIMD2<Float> {
        get { SIMD2<Float>(viewportSize_packed.x, viewportSize_packed.y) }
        set { viewportSize_packed = SIMD4<Float>(newValue.x, newValue.y, 0.0, 0.0) }
    }

    var nearPlane: Float {
        get { nearPlane_packed.x }
        set { nearPlane_packed.x = newValue }
    }

    var farPlane: Float {
        get { nearPlane_packed.y }
        set { nearPlane_packed.y = newValue }
    }
}
