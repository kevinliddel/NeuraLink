// GodRayShader.metal
// NeuraLink
//
// Volumetric god rays (crepuscular light shafts) — three passes:
//   1. godray_mask_fragment    — sky-only occluder mask at ¼ resolution
//   2. godray_blur_fragment    — radial blur toward the sun (GPU Gems 3 algorithm)
//   3. godray_composite_fragment — additive blend of tinted rays into the scene buffer

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniform layout (must match GodRayUniforms in Swift, 96 bytes)

struct GodRayUniforms {
    float4x4 inverseProjection;  // offset  0, 64 bytes — for view-dir reconstruction
    float2   sunScreenUV;        // offset 64,  8 bytes — sun position in [0,1] UV
    float    sunIntensity;       // offset 72,  4 bytes
    float    sunHeight;          // offset 76,  4 bytes — raw y component (signed)
    float4   sunColor;           // offset 80, 16 bytes — rgb + unused w
};                               // total: 96 bytes

// MARK: - Vertex (large-triangle, reused by all three passes)

struct GodRayVert {
    float4 position [[position]];
    float2 uv;
};

vertex GodRayVert godray_vertex(uint vid [[vertex_id]]) {
    const float2 pos[3] = { float2(-1,-3), float2(-1, 1), float2(3, 1) };
    GodRayVert out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv       = pos[vid] * float2(0.5, -0.5) + 0.5;
    return out;
}

// MARK: - Pass 1: occluder mask
//
// Sky pixels (depth ≈ 1) near the sun contribute brightness.
// Geometry pixels are fully black (they occlude the rays).

fragment float4 godray_mask_fragment(
    GodRayVert             in       [[stage_in]],
    depth2d<float>         depthTex [[texture(0)]],
    constant GodRayUniforms& u      [[buffer(0)]]
) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);

    float depth = depthTex.sample(nearest, in.uv);
    if (depth < 0.9999) return float4(0);  // geometry pixel: occluder

    // Angular proximity to sun in screen UV space.
    // Correct for typical portrait aspect ratio so the disc is circular.
    float2 delta  = in.uv - u.sunScreenUV;
    delta.x      *= 0.5625;  // ~9:16 correction; keeps disc round on phone screens
    float dist    = length(delta);

    // Soft disc that fades out beyond ~0.25 UV radius from the sun.
    float disc = 1.0 - smoothstep(0.0, 0.25, dist);

    // Scale by sun intensity and fade below the horizon.
    float h       = u.sunHeight;                        // signed height [-1,1]
    float dayFade = smoothstep(-0.08, 0.12, h);        // appears just above horizon
    float weight  = disc * u.sunIntensity * dayFade;

    return float4(weight, weight, weight, 1.0);
}

// MARK: - Pass 2: radial blur (volumetric light scattering)
//
// March each pixel backward along a ray toward the sun, accumulating
// masked brightness with exponential decay — GPU Gems 3 §13.

fragment float4 godray_blur_fragment(
    GodRayVert                       in      [[stage_in]],
    texture2d<float, access::sample> maskTex [[texture(0)]],
    constant GodRayUniforms&         u       [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    const int   NUM_SAMPLES = 64;
    const float decay       = 0.97;
    const float density     = 0.92;   // march distance as a fraction of sun distance
    const float weight      = 0.40;
    const float exposure    = 0.65;

    float2 texCoord = in.uv;
    float2 step     = (texCoord - u.sunScreenUV) * (density / float(NUM_SAMPLES));

    float illuminationDecay = 1.0;
    float4 color            = float4(0);

    for (int i = 0; i < NUM_SAMPLES; i++) {
        texCoord          -= step;
        float4 samp        = maskTex.sample(s, texCoord);
        samp              *= illuminationDecay * weight;
        color             += samp;
        illuminationDecay *= decay;
    }

    return color * exposure;
}

// MARK: - Pass 3: composite
//
// Tints the blurred rays with the sun colour and additively blends into the framebuffer.
// Only pixels that belong to city/campus scene geometry receive rays.
// Sky pixels (depth == 1.0 clear value) and the sun disc are excluded, which also
// removes the dark anti-sun sphere artifact caused by contrast against the bright halo.

fragment float4 godray_composite_fragment(
    GodRayVert                       in       [[stage_in]],
    texture2d<float, access::sample> raysTex  [[texture(0)]],
    depth2d<float>                   depthTex [[texture(1)]],
    constant GodRayUniforms&         u        [[buffer(0)]]
) {
    constexpr sampler s(filter::linear,  address::clamp_to_edge);
    constexpr sampler d(filter::nearest, address::clamp_to_edge);

    // Discard sky / unrendered pixels — only city/campus ground gets ray brightening.
    float depth = depthTex.sample(d, in.uv);
    if (depth >= 0.9999f) discard_fragment();

    float  rayBrightness = raysTex.sample(s, in.uv).r;
    float3 tinted        = rayBrightness * u.sunColor.rgb;
    return float4(tinted, rayBrightness);
}
