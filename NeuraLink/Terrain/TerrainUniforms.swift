//
//  TerrainUniforms.swift
//  NeuraLink
//
//  Created by Dedicatus on 18/04/2026.
//

import simd

/// GPU uniforms for the terrain fragment shader.
/// Layout must exactly match `TerrainUniforms` in TerrainShader.metal.
/// Stride = 240 bytes.
struct TerrainUniforms {
    var viewProjection: simd_float4x4       // offset   0 — transforms world → clip
    var lightViewProjection: simd_float4x4  // offset  64 — tight shadow map (VRM, ±7 m)
    var wideLightViewProjection: simd_float4x4 // offset 128 — wide shadow map (trees, ±35 m)
    var sunDirection: SIMD4<Float>          // offset 192 — xyz = toward-sun, w = sun height
    var groundColor: SIMD4<Float>           // offset 208 — xyz = dirt earth base colour
    var terrainParams: SIMD4<Float>         // offset 224 — x=unused y=amp z=shadowSoft w=time
}

/// Per-primitive uniform written once per shadow-pass draw call.
/// Stride = 64 bytes.
struct ShadowPassUniforms {
    var lightModelViewProjection: simd_float4x4  // offset 0
}
