//
//  TerrainUniforms.swift
//  NeuraLink
//
//  Created by Dedicatus on 18/04/2026.
//

import simd

/// GPU uniforms for the terrain fragment shader.
/// Layout must exactly match `TerrainUniforms` in TerrainShader.metal.
/// Stride = 176 bytes.
struct TerrainUniforms {
    var viewProjection: simd_float4x4  // offset   0 — transforms y=0 quad to clip space
    var lightViewProjection: simd_float4x4  // offset  64 — transforms world pos to light clip
    var sunDirection: SIMD4<Float>  // offset 128 — xyz = toward-sun unit vector
    var snowColor: SIMD4<Float>  // offset 144 — xyz = snow base colour
    var terrainParams: SIMD4<Float>  // offset 160 — x=duneScale y=duneAmp z=shadowSoft w=time
}

/// Per-primitive uniform written once per shadow-pass draw call.
/// Stride = 64 bytes.
struct ShadowPassUniforms {
    var lightModelViewProjection: simd_float4x4  // offset 0
}
