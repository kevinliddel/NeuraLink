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
/// Total size: 64 + 7×16 + 48 + 2×16 = 256 bytes.
struct SkyUniformsData {
    /// Inverse combined view-projection matrix — maps NDC → world space for ray casting.
    var invViewProjection: simd_float4x4       // 64 bytes, offset   0

    /// Sun direction xyz (world-space, pointing toward sun) + intensity w.
    var sunDirectionAndIntensity: SIMD4<Float> // 16 bytes, offset  64

    /// Sun disc colour rgb + disc exponent w (higher = tighter disc).
    var sunColorAndSize: SIMD4<Float>          // 16 bytes, offset  80

    /// The night's own glow at the horizon rgb (weighted by how dark it
    /// is), w = rain [0, 1].
    var nightGlowLow: SIMD4<Float>             // 16 bytes, offset  96

    /// The night's own glow at the zenith rgb, w unused.
    var nightGlowHigh: SIMD4<Float>            // 16 bytes, offset 112

    /// Cloud animation: x=elapsed time, y=scroll speed, z=coverage [0,1], w=star visibility.
    var cloudParams: SIMD4<Float>              // 16 bytes, offset 128

    /// Moon direction xyz (world-space, pointing toward the moon) + lit fraction w.
    var moonDirectionAndPhase: SIMD4<Float>    // 16 bytes, offset 144

    /// x = moon angular radius (radians), z = moon brightness against full,
    /// y and w unused.
    var bodyParams: SIMD4<Float>               // 16 bytes, offset 160

    /// Star catalogue frame (J2000 equatorial) → world. Orthonormal, so its
    /// transpose takes a view ray back into the stars' frame.
    var starRotation: simd_float3x3            // 48 bytes, offset 176

    /// cos of the moon's angular radius × 1.48 (where it starts hiding the
    /// stars), 1 (where it hides them all), 1.03 and 0.97 (its disc's soft
    /// edge): the same every pixel, so worked out once here.
    var moonEdges: SIMD4<Float>                // 16 bytes, offset 224

    /// x = cloud layers drawn (2, or 1 on a hot phone), yzw unused.
    var detail: SIMD4<Float>                   // 16 bytes, offset 240
    // Total: 256 bytes
}
