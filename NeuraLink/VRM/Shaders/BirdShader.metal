//
//  BirdShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 21/04/2026.
//
//  Low-poly instanced birds with progressive wing-flap and sky-driven lighting.

#include <metal_stdlib>
using namespace metal;

// MARK: - Structs (layout must match Swift counterparts exactly)

struct BirdUniforms {
    float4x4 viewProjection;  // world → clip
    float4   sunDirection;    // xyz = toward-sun unit vector, w = intensity
    float4   sunColor;        // xyz = key-light colour
    float4   ambientColor;    // xyz = ambient colour
};

struct BirdInstanceData {
    float4 positionAndYaw;    // xyz = world position, w = yaw (radians around Y)
    float4 wingAngleAndScale; // x = wing angle (radians), y = uniform scale
};

struct BirdVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    int    part     [[attribute(2)]];  // 0 = body/tail, 1 = leftWing, 2 = rightWing
};

struct BirdVertexOut {
    float4 position    [[position]];
    float3 worldNormal;
};

// MARK: - Wing animation

/// Lifts wing vertices proportionally to their X distance from the body centreline.
/// Applied in object space before scale, producing a natural arcing flap.
static float3 applyWingFlap(float3 pos, float wingAngle) {
    float reach = clamp(abs(pos.x) / 0.18f, 0.0f, 1.0f);  // 0 at body, 1 at tip
    pos.y += sin(wingAngle) * reach * 0.10f;
    return pos;
}

// MARK: - Vertex

vertex BirdVertexOut bird_vertex(
    BirdVertexIn               in         [[stage_in]],
    constant BirdUniforms     &uniforms   [[buffer(1)]],
    constant BirdInstanceData *instances  [[buffer(2)]],
    uint                       instanceID [[instance_id]]
) {
    BirdInstanceData inst = instances[instanceID];
    float  yaw       = inst.positionAndYaw.w;
    float  wingAngle = inst.wingAngleAndScale.x;
    float  scale     = inst.wingAngleAndScale.y;

    // Animate wing vertices in object space (before scale is applied)
    float3 objPos = in.position;
    if (in.part == 1 || in.part == 2) {
        objPos = applyWingFlap(objPos, wingAngle);
    }

    float3 localPos = objPos * scale;
    float3 localNrm = in.normal;

    // Rotate around Y axis to align nose (-Z) with the bird's heading (yaw)
    float sinY = sin(yaw), cosY = cos(yaw);
    float3 worldPos = float3(
         localPos.x * cosY + localPos.z * sinY,
         localPos.y,
        -localPos.x * sinY + localPos.z * cosY
    ) + inst.positionAndYaw.xyz;

    float3 worldNrm = normalize(float3(
         localNrm.x * cosY + localNrm.z * sinY,
         localNrm.y,
        -localNrm.x * sinY + localNrm.z * cosY
    ));

    BirdVertexOut out;
    out.position    = uniforms.viewProjection * float4(worldPos, 1.0f);
    out.worldNormal = worldNrm;
    return out;
}

// MARK: - Fragment

fragment float4 bird_fragment(
    BirdVertexOut         in       [[stage_in]],
    constant BirdUniforms &uniforms [[buffer(1)]]
) {
    // Dark warm silhouette — reads naturally as a distant bird against the sky
    const float3 birdColor = float3(0.16f, 0.13f, 0.10f);

    float3 N    = normalize(in.worldNormal);
    float3 L    = normalize(uniforms.sunDirection.xyz);
    // abs(NdotL) gives equal lighting on both faces of each thin polygon
    float  lit  = max(abs(dot(N, L)) * uniforms.sunDirection.w, 0.0f);

    float3 color = birdColor * (uniforms.ambientColor.rgb + uniforms.sunColor.rgb * lit);
    return float4(color, 1.0f);
}
