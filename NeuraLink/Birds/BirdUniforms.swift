//
//  BirdUniforms.swift
//  NeuraLink
//
//  Created by Dedicatus on 21/04/2026.
//

import simd

/// GPU uniform data for bird rendering.
/// Memory layout MUST match `BirdUniforms` in BirdShader.metal exactly.
/// Total: 64 + 3×16 = 112 bytes.
struct BirdUniformsData {
    /// World → clip transform.
    var viewProjection: simd_float4x4       // 64 bytes, offset  0
    /// xyz = unit vector toward sun, w = key-light intensity.
    var sunDirection: SIMD4<Float>           // 16 bytes, offset 64
    /// xyz = key-light colour, w = unused.
    var sunColor: SIMD4<Float>               // 16 bytes, offset 80
    /// xyz = ambient colour, w = unused.
    var ambientColor: SIMD4<Float>           // 16 bytes, offset 96
}

/// Per-instance GPU data uploaded once per bird per frame.
/// Memory layout MUST match `BirdInstanceData` in BirdShader.metal exactly.
/// Total: 32 bytes.
struct BirdInstanceGPUData {
    /// xyz = world position, w = yaw (radians around Y axis).
    var positionAndYaw: SIMD4<Float>         // 16 bytes
    /// x = wing angle (radians), y = uniform scale, zw = unused.
    var wingAngleAndScale: SIMD4<Float>      // 16 bytes
}
