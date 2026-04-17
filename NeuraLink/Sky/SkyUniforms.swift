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
/// Total size: 64 + 5×16 = 144 bytes.
struct SkyUniformsData {
    /// Inverse combined view-projection matrix — maps NDC → world space for ray casting.
    var invViewProjection: simd_float4x4       // 64 bytes, offset   0

    /// Sun direction xyz (world-space, pointing toward sun) + intensity w.
    var sunDirectionAndIntensity: SIMD4<Float> // 16 bytes, offset  64

    /// Sun disc colour rgb + angular disc half-size w (cosine of angle).
    var sunColorAndSize: SIMD4<Float>          // 16 bytes, offset  80

    /// Cloud tint rgb + coverage fraction w [0, 1].
    var cloudColorAndCoverage: SIMD4<Float>    // 16 bytes, offset  96

    /// Cloud animation: x=elapsed time, y=scroll speed, z=noise density, w=star visibility.
    var cloudParams: SIMD4<Float>              // 16 bytes, offset 112

    /// Atmospheric turbidity x [2–10], yzw unused.
    var turbidityAndFlags: SIMD4<Float>        // 16 bytes, offset 128
    // Total: 144 bytes
}
