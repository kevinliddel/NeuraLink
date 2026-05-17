// SSAOShader.metal
// NeuraLink
//
// Screen-Space Ambient Occlusion — three passes:
//   1. ssao_fragment      — reads depth, reconstructs normals, emits AO to r8Unorm target
//   2. ssao_blur_fragment — 3×3 box blur on the AO texture
//   3. ssao_composite_fragment — fullscreen multiply blend into the scene colour buffer

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared uniform layout (must match SSAOUniforms in Swift, 160 bytes total)

struct SSAOUniforms {
    float4x4 projectionMatrix;    // offset   0, 64 bytes
    float4x4 inverseProjection;   // offset  64, 64 bytes
    float4   screenParams;        // offset 128  x=W, y=H, z=radius(m), w=bias(m)
    float4   aoParams;            // offset 144  x=power, yzw=unused
};                                // total: 160 bytes

// MARK: - Shared vertex output

struct SSAOVert {
    float4 position [[position]];
    float2 uv;
};

// MARK: - Fullscreen large-triangle vertex (no vertex buffer needed)

vertex SSAOVert ssao_vertex(uint vid [[vertex_id]]) {
    // Three corners that cover the NDC clip space exactly.
    const float2 pos[3] = { float2(-1,-3), float2(-1, 1), float2(3, 1) };
    SSAOVert out;
    out.position = float4(pos[vid], 0.0, 1.0);
    // Map NDC → UV, flipping Y so UV(0,0) = top-left (Metal texture convention).
    out.uv = pos[vid] * float2(0.5, -0.5) + 0.5;
    return out;
}

// MARK: - Depth → view-space position

static float3 viewPosFromDepth(float2 uv, float depth, float4x4 invProj) {
    // Metal NDC: x ∈ [-1,1], y ∈ [-1,1] (y+ = up), z ∈ [0,1].
    float4 ndc = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    float4 vs  = invProj * ndc;
    return vs.xyz / vs.w;
}

// MARK: - Per-pixel random rotation angle (hash, avoids noise texture dependency)

static float randomAngle(float2 uv) {
    float2 seed = floor(uv * 4.0);    // 4×4 tile grid
    return fract(sin(dot(seed, float2(127.1, 311.7))) * 43758.5453) * (2.0 * M_PI_F);
}

// MARK: - Hemisphere kernel (16 samples, four elevation rings × four azimuths)
//
// All samples have z > 0 (upper hemisphere in tangent space).
// Scales are distributed from 0.10 → 0.96 with quadratic acceleration so
// near-contact samples receive most weight (better crease/cavity detail).

static float3 kernelSample(int i) {
    const float3 dirs[16] = {
        float3( 0.38, 0.00, 0.93), float3( 0.00, 0.38, 0.93),
        float3(-0.38, 0.00, 0.93), float3( 0.00,-0.38, 0.93),
        float3( 0.71, 0.00, 0.71), float3( 0.00, 0.71, 0.71),
        float3(-0.71, 0.00, 0.71), float3( 0.00,-0.71, 0.71),
        float3( 0.84, 0.00, 0.54), float3( 0.00, 0.84, 0.54),
        float3(-0.84, 0.00, 0.54), float3( 0.00,-0.84, 0.54),
        float3( 0.93, 0.00, 0.38), float3( 0.00, 0.93, 0.38),
        float3(-0.93, 0.00, 0.38), float3( 0.00,-0.93, 0.38)
    };
    const float scales[16] = {
        0.10, 0.12, 0.16, 0.22,
        0.30, 0.40, 0.52, 0.62,
        0.70, 0.77, 0.83, 0.87,
        0.90, 0.93, 0.95, 0.96
    };
    return dirs[i] * scales[i];
}

// MARK: - SSAO fragment

fragment float4 ssao_fragment(
    SSAOVert               in       [[stage_in]],
    depth2d<float>         depthTex [[texture(0)]],
    constant SSAOUniforms& u        [[buffer(0)]]
) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);

    float depth = depthTex.sample(nearest, in.uv);
    // Sky / far-plane pixels carry no geometry → full brightness (no AO).
    if (depth >= 0.9999) return float4(1.0);

    float2 texelSize = 1.0 / u.screenParams.xy;
    float3 origin = viewPosFromDepth(in.uv, depth, u.inverseProjection);

    // Reconstruct view-space normal from depth derivatives.
    // Using (posU − origin) × (posR − origin) gives outward-facing normal
    // (toward camera) for front-facing geometry.
    float dR = depthTex.sample(nearest, in.uv + float2(texelSize.x, 0.0));
    float dU = depthTex.sample(nearest, in.uv + float2(0.0, texelSize.y));
    float3 posR = viewPosFromDepth(in.uv + float2(texelSize.x, 0.0), dR, u.inverseProjection);
    float3 posU = viewPosFromDepth(in.uv + float2(0.0, texelSize.y),  dU, u.inverseProjection);
    float3 normal = normalize(cross(posU - origin, posR - origin));

    // Build TBN from surface normal + per-pixel random tangent (Gram-Schmidt).
    float  angle      = randomAngle(in.uv);
    float3 rndTangent = float3(cos(angle), sin(angle), 0.0);
    float3 tangent    = normalize(rndTangent - normal * dot(rndTangent, normal));
    float3 bitangent  = cross(normal, tangent);
    float3x3 TBN      = float3x3(tangent, bitangent, normal);

    float radius = u.screenParams.z;
    float bias   = u.screenParams.w;

    float occlusion = 0.0;
    for (int i = 0; i < 16; i++) {
        // Transform kernel sample to view space and offset from origin.
        float3 sampleVS   = origin + TBN * (kernelSample(i) * radius);

        // Project to screen UV.
        float4 sampleClip = u.projectionMatrix * float4(sampleVS, 1.0);
        float3 sampleNDC  = sampleClip.xyz / sampleClip.w;
        float2 sampleUV   = float2(sampleNDC.x * 0.5 + 0.5, 0.5 - sampleNDC.y * 0.5);

        if (any(sampleUV < 0.0) || any(sampleUV > 1.0)) continue;

        float  sampledDepth = depthTex.sample(nearest, sampleUV);
        float3 sampledPos   = viewPosFromDepth(sampleUV, sampledDepth, u.inverseProjection);

        // Range check: suppress occlusion from surfaces at very different depths
        // (avoids dark halos at depth discontinuities).
        float dist      = abs(origin.z - sampledPos.z);
        float rangeCheck = smoothstep(0.0, 1.0, radius / max(dist, 0.001));

        // A sample is occluded when real geometry is closer to the camera than
        // the sample position (sampledPos.z is less negative = closer).
        occlusion += (sampledPos.z >= sampleVS.z + bias ? 1.0 : 0.0) * rangeCheck;
    }

    float ao = 1.0 - (occlusion / 16.0);
    ao = pow(saturate(ao), u.aoParams.x);
    return float4(ao, ao, ao, 1.0);
}

// MARK: - Blur fragment (3×3 box filter on the AO texture)

fragment float4 ssao_blur_fragment(
    SSAOVert                         in    [[stage_in]],
    texture2d<float, access::sample> aoTex [[texture(0)]],
    constant SSAOUniforms&           u     [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 texelSize = 1.0 / u.screenParams.xy;
    float  result    = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            result += aoTex.sample(s, in.uv + float2(x, y) * texelSize).r;
        }
    }
    float ao = result / 9.0;
    return float4(ao, ao, ao, 1.0);
}

// MARK: - Composite fragment
//
// Rendered with multiply blend (src × dst → framebuffer × AO).
// Pipeline: sourceRGBBlendFactor = .destinationColor, dstRGBBlendFactor = .zero.

fragment float4 ssao_composite_fragment(
    SSAOVert                         in    [[stage_in]],
    texture2d<float, access::sample> aoTex [[texture(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float ao = aoTex.sample(s, in.uv).r;
    return float4(ao, ao, ao, 1.0);
}
