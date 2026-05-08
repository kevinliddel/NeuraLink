//
//  TreeShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 07/05/2026.
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Vertex layouts

struct TreeShadowVertexIn {
    float3 position [[attribute(0)]];
};

struct TreeVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

// MARK: - Uniforms (must match Swift structs)

struct TreeShadowUniforms {
    float4x4 lightViewProjection;
};

struct TreeUniforms {
    float4x4 viewProjection;
    float4x4 lightViewProjection;
    float4   sunDirection;  // xyz = effective sun dir, w = sun height (signed)
    float4   treeParams;    // x = shadowSoft
};

// MARK: - Interpolants

struct TreeVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 texcoord;
};

// MARK: - Shadow depth vertex

vertex float4 tree_shadow_vertex(
    TreeShadowVertexIn in      [[stage_in]],
    constant TreeShadowUniforms &u [[buffer(1)]],
    constant float4x4 *instances   [[buffer(2)]],
    uint iid [[instance_id]]
) {
    float4 worldPos = instances[iid] * float4(in.position, 1.0);
    return u.lightViewProjection * worldPos;
}

// MARK: - Main vertex

vertex TreeVertexOut tree_vertex(
    TreeVertexIn in            [[stage_in]],
    constant TreeUniforms &u   [[buffer(1)]],
    constant float4x4 *instances [[buffer(2)]],
    uint iid [[instance_id]]
) {
    float4x4 model = instances[iid];
    float4   wp    = model * float4(in.position, 1.0);

    // Upper-left 3x3 for normal transform (no non-uniform scale assumed)
    float3x3 nm = float3x3(model[0].xyz, model[1].xyz, model[2].xyz);

    TreeVertexOut out;
    out.position = u.viewProjection * wp;
    out.worldPos = wp.xyz;
    out.normal   = normalize(nm * in.normal);
    out.texcoord = in.texcoord;
    return out;
}

// MARK: - Shadow PCF (9-tap)

static float treeSampleShadow(
    texture2d<float> shadowMap,
    sampler          smp,
    float3           worldPos,
    float4x4         lightVP,
    float            softness
) {
    float4 lc  = lightVP * float4(worldPos, 1.0);
    float3 ndc = lc.xyz / lc.w;
    if (any(abs(ndc.xy) > 1.0f) || ndc.z < 0.0f || ndc.z > 1.0f) return 0.0f;

    float2 uv   = float2(ndc.x * 0.5f + 0.5f, -ndc.y * 0.5f + 0.5f);
    float  recv = ndc.z - 0.002f;
    float2 ts   = softness / float2(shadowMap.get_width(), shadowMap.get_height());

    float s = 0.0f;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
            s += (recv > shadowMap.sample(smp, uv + float2(dx, dy) * ts).r) ? 1.0f : 0.0f;
    return s / 9.0f;
}

// MARK: - Fragment

fragment float4 tree_fragment(
    TreeVertexOut          in              [[stage_in]],
    constant TreeUniforms &u              [[buffer(1)]],
    constant float4       &baseColorFactor [[buffer(2)]],
    texture2d<float>       albedo          [[texture(0)]],
    texture2d<float>       shadowMap       [[texture(1)]],
    sampler                shadowSmp       [[sampler(0)]]
) {
    constexpr sampler linearSmp(filter::linear, address::repeat);
    float4 color = albedo.sample(linearSmp, in.texcoord) * baseColorFactor;

    // Hard alpha clip for leaf geometry
    if (color.a < 0.2f) discard_fragment();

    float3 normal  = normalize(in.normal);
    float3 sunDir  = u.sunDirection.xyz;
    float  soft    = u.treeParams.x;

    // Two-sided diffuse so back-lit leaves stay visible
    float NdotL = max(abs(dot(normal, sunDir)), 0.0f);
    float sunH  = u.sunDirection.w;
    float ambient = 0.35f + max(sunH, 0.0f) * 0.20f;  // [0.35 .. 0.55]
    float shadow  = soft > 0.0f
        ? treeSampleShadow(shadowMap, shadowSmp, in.worldPos, u.lightViewProjection, soft)
        : 0.0f;

    // Energy-conserving: diffuse headroom = (1 - ambient) so total never exceeds 1
    float diffuse = max(1.0f - ambient, 0.0f) * NdotL * (1.0f - shadow * 0.65f);
    float lit = saturate(ambient + diffuse);

    // Light atmospheric haze matching terrain
    float dist  = length(in.worldPos.xz);
    float haze  = smoothstep(20.0f, 80.0f, dist);
    float3 hazeCol = mix(float3(0.72f, 0.78f, 0.88f), float3(0.55f, 0.65f, 0.80f), max(sunH, 0.0f));
    float3 rgb  = mix(color.rgb * lit, hazeCol, haze * 0.50f);

    return float4(rgb, color.a);
}
