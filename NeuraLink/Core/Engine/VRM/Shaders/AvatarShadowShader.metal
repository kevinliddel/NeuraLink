//
//  AvatarShadowShader.metal
//  NeuraLink
//
//  The avatar's self-shadow map (VRMRenderer+AvatarShadow): depth from the
//  MToon key light, in a frustum fitted around the character so a texel is
//  about a millimetre. Skinned and rigid parts share one vertex function;
//  the hull starts from the morphed positions (an open mouth shadows the
//  teeth it shows), and cutout texels are discarded so hair cards cast the
//  strands they paint, not their rectangles.
//
//  Created by Dedicatus on 23/10/2026.
//

#include <metal_stdlib>
using namespace metal;

struct AvatarShadowVertexIn {
    float3 position [[attribute(0)]];
    float2 texCoord [[attribute(2)]];
    uint4 joints [[attribute(4)]];
    float4 weights [[attribute(5)]];
};

/// Mirrors `AvatarShadowDrawUniforms` (Swift).
struct AvatarShadowDrawUniforms {
    float4x4 lightViewProjection;
    float4x4 modelMatrix;
    float4 baseColorFactor;
    float alphaCutoff;
    int alphaTest;
    int skinned;
    int hasMorphed;
};

struct AvatarShadowOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex AvatarShadowOut avatar_shadow_vertex(AvatarShadowVertexIn in [[stage_in]],
                                            constant AvatarShadowDrawUniforms& uniforms [[buffer(1)]],
                                            const device float3* morphedPositions [[buffer(20)]],
                                            constant float4x4* jointMatrices [[buffer(25)]],
                                            uint vertexID [[vertex_id]]) {
    float3 position = uniforms.hasMorphed > 0 ? float3(morphedPositions[vertexID]) : in.position;
    float4 local = float4(position, 1.0);
    if (uniforms.skinned > 0) {
        float4 weights = in.weights;
        float total = dot(weights, float4(1.0));
        weights = total > 1e-6 ? weights / total : float4(1.0, 0.0, 0.0, 0.0);
        uint4 joints = min(in.joints, uint4(255));
        float4x4 skin = jointMatrices[joints.x] * weights.x + jointMatrices[joints.y] * weights.y
                      + jointMatrices[joints.z] * weights.z + jointMatrices[joints.w] * weights.w;
        local = skin * local;
    }
    AvatarShadowOut out;
    out.position = uniforms.lightViewProjection * (uniforms.modelMatrix * local);
    out.texCoord = in.texCoord;
    return out;
}

/// Opaque parts write depth as they are; cutout parts drop their
/// transparent texels.
fragment void avatar_shadow_fragment(AvatarShadowOut in [[stage_in]],
                                     constant AvatarShadowDrawUniforms& uniforms [[buffer(1)]],
                                     texture2d<float> baseColorTexture [[texture(0)]],
                                     sampler textureSampler [[sampler(0)]]) {
    if (uniforms.alphaTest > 0) {
        float alpha = uniforms.baseColorFactor.a * baseColorTexture.sample(textureSampler, in.texCoord).a;
        if (alpha < uniforms.alphaCutoff) { discard_fragment(); }
    }
}
