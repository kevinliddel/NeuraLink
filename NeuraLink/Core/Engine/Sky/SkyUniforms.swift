//
//  SkyUniforms.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import simd

/// GPU uniform data for sky rendering.
/// Memory layout MUST match `SkyUniforms` in SkyShader.metal exactly.
///
/// Total size: 64 + 7×16 + 48 = 224 bytes.
struct SkyUniformsData {
    /// Inverse combined view-projection matrix — maps NDC → world space for ray casting.
    var invViewProjection: simd_float4x4       // 64 bytes, offset   0

    /// Sun direction xyz (world-space, pointing toward sun) + intensity w.
    var sunDirectionAndIntensity: SIMD4<Float> // 16 bytes, offset  64

    /// Sun disc colour rgb + disc exponent w (higher = tighter disc).
    var sunColorAndSize: SIMD4<Float>          // 16 bytes, offset  80

    /// Sky gradient bottom colour rgb, w unused.
    var skyColorLow: SIMD4<Float>              // 16 bytes, offset  96

    /// Sky gradient top colour rgb, w unused.
    var skyColorHigh: SIMD4<Float>             // 16 bytes, offset 112

    /// Cloud animation: x=elapsed time, y=scroll speed, z=coverage [0,1], w=star visibility.
    var cloudParams: SIMD4<Float>              // 16 bytes, offset 128

    /// Moon direction xyz (world-space, pointing toward the moon) + lit fraction w.
    var moonDirectionAndPhase: SIMD4<Float>    // 16 bytes, offset 144

    /// x = moon angular radius (radians), y = turbidity, z = moon brightness
    /// against full, w unused.
    var bodyParams: SIMD4<Float>               // 16 bytes, offset 160

    /// Star catalogue frame (J2000 equatorial) → world. Orthonormal, so its
    /// transpose takes a view ray back into the stars' frame.
    var starRotation: simd_float3x3            // 48 bytes, offset 176
    // Total: 224 bytes
}
