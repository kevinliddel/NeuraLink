//
//  ShadowShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 18/04/2026.
//
//  Depth-only shadow-map pass for non-skinned and skinned VRM geometry.

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniform

struct ShadowPassUniforms {
    float4x4 lightModelViewProjection;
};

// MARK: - Non-skinned shadow pass

struct ShadowVertexIn {
    float3 position [[attribute(0)]];
};

vertex float4 shadow_vertex(
    ShadowVertexIn in [[stage_in]],
    constant ShadowPassUniforms &uniforms [[buffer(1)]]
) {
    return uniforms.lightModelViewProjection * float4(in.position, 1.0);
}

// MARK: - Skinned shadow pass

struct ShadowSkinnedIn {
    float3 position [[attribute(0)]];
    uint4  joints   [[attribute(4)]];
    float4 weights  [[attribute(5)]];
};

vertex float4 shadow_skinned_vertex(
    ShadowSkinnedIn in [[stage_in]],
    constant ShadowPassUniforms &uniforms [[buffer(1)]],
    constant float4x4 *jointMatrices [[buffer(4)]]
) {
    float4x4 skin =
        in.weights.x * jointMatrices[in.joints.x] +
        in.weights.y * jointMatrices[in.joints.y] +
        in.weights.z * jointMatrices[in.joints.z] +
        in.weights.w * jointMatrices[in.joints.w];
    float4 worldPos = skin * float4(in.position, 1.0);
    return uniforms.lightModelViewProjection * worldPos;
}
