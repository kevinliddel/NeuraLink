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
    float4x4 inverseViewProjection; // offset  0, 64 bytes — inv(P*V) for world-pos reconstruction
    float2   sunScreenUV;           // offset 64,  8 bytes — sun position in [0,1] UV
    float    sunIntensity;          // offset 72,  4 bytes
    float    sunHeight;             // offset 76,  4 bytes — raw y component (signed)
    float4   sunColor;              // offset 80, 16 bytes — rgb=sun tint, w=ground Y threshold
};                                  // total: 96 bytes (unchanged)

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
// Rays are restricted to near-ground surfaces (puddles, floor tiles) via a smooth Y fade
// that starts at the environment ground base (sunColor.w, nominally 0.0) and reaches zero
// at +0.3 m above it. This excludes buildings, foliage, the VRM character body, and the
// sun mesh without any hard-edge oscillation at the boundary.
// Sky pixels (depth == 1.0 clear value) are always discarded first.

fragment float4 godray_composite_fragment(
    GodRayVert                       in       [[stage_in]],
    texture2d<float, access::sample> raysTex  [[texture(0)]],
    depth2d<float>                   depthTex [[texture(1)]],
    constant GodRayUniforms&         u        [[buffer(0)]]
) {
    constexpr sampler s(filter::linear,  address::clamp_to_edge);
    constexpr sampler d(filter::nearest, address::clamp_to_edge);

    // Discard sky / unrendered pixels (cleared to depth 1.0 in the pre-pass).
    float depth = depthTex.sample(d, in.uv);
    if (depth >= 0.9999f) discard_fragment();

    // Reconstruct world-space Y from depth.
    // NDC xy: UV(0,0)=top-left → NDC(-1,+1); UV(1,1)=bottom-right → NDC(+1,-1).
    float2 ndc    = in.uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f);
    float4 clip   = float4(ndc, depth, 1.0f);
    float4 worldH = u.inverseViewProjection * clip;
    float  worldY = worldH.y / worldH.w;

    // Smooth fade: full brightness at ground level, zero at +0.3 m above.
    // sunColor.w = ground base Y (0.0 in this engine).
    // Range [-0.1, +0.3] covers sunken puddles and flat floor tiles while excluding
    // anything taller than a kerb. Smooth fade eliminates the precision-boundary
    // flicker that a hard cutoff causes near the transition height.
    float groundBase = u.sunColor.w;
    float fade = 1.0f - smoothstep(groundBase - 0.1f, groundBase + 0.3f, worldY);
    if (fade <= 0.01f) discard_fragment();

    float  rayBrightness = raysTex.sample(s, in.uv).r;
    float3 tinted        = rayBrightness * u.sunColor.rgb;
    return float4(tinted * fade, rayBrightness * fade);
}
