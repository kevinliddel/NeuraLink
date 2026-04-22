//
//  SkyShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//
//  Time-of-day sky: simple vertical gradient with time-driven colour palettes,
//  sun disc, star field, dome clouds, and moon disc.

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms (must match SkyUniformsData in Swift, 144 bytes)

struct SkyUniforms {
    float4x4 invViewProjection;         // NDC → world-space ray cast
    float4   sunDirectionAndIntensity;  // xyz = toward-sun unit vector, w = intensity
    float4   sunColorAndSize;           // xyz = sun disc colour, w = disc exponent
    float4   skyColorLow;               // xyz = gradient bottom colour
    float4   skyColorHigh;              // xyz = gradient top colour
    float4   cloudParams;               // x = elapsed time, y = scroll speed, z = coverage, w = star vis
};

// MARK: - Vertex — fullscreen triangle (no vertex buffer needed)

struct SkyOut {
    float4 position [[position]];
    float2 uv;
};

vertex SkyOut sky_vertex(uint vid [[vertex_id]]) {
    constexpr float2 pos[3] = {
        float2(-1.0f, -3.0f),
        float2(-1.0f,  1.0f),
        float2( 3.0f,  1.0f)
    };
    SkyOut out;
    out.position = float4(pos[vid], 0.9999f, 1.0f);
    out.uv = pos[vid] * 0.5f + 0.5f;
    return out;
}

// MARK: - Noise helpers

static float skyHash(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
}

static float skyValueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    return mix(mix(skyHash(i),               skyHash(i + float2(1,0)), u.x),
               mix(skyHash(i + float2(0,1)), skyHash(i + float2(1,1)), u.x), u.y);
}

static float skyFbm(float2 p) {
    float val = 0.0f, amp = 0.5f;
    for (int i = 0; i < 6; i++) { val += amp * skyValueNoise(p); p *= 2.0f; amp *= 0.5f; }
    return val;
}

// MARK: - Stars

static float starField(float3 viewDir, float time) {
    if (viewDir.y < 0.0f) return 0.0f;
    float2 uv = float2(atan2(viewDir.x, viewDir.z) * (0.5f / M_PI_F) + 0.5f,
                       acos(viewDir.y) * (1.0f / M_PI_F));
    float2 cell = floor(uv * 250.0f);
    float rnd   = skyHash(cell + floor(time * 0.01f));
    float bright = step(0.96f, rnd);
    float2 local = fract(uv * 250.0f) - 0.5f;
    // Diamond shape: L1 norm gives a rotated-square (♦) instead of a circle
    float dist = abs(local.x) + abs(local.y);
    return bright * smoothstep(0.18f, 0.02f, dist);
}

// MARK: - Dome-projected clouds

// Lower-sky layer: dome projection, visible from near-horizon to zenith.
static float cloudLayer(float3 viewDir, float time, float speed, float density, float coverage) {
    if (viewDir.y < 0.02f || coverage < 0.001f) return 0.0f;
    float2 cloudUV = viewDir.xz / max(viewDir.y, 0.20f);  // clamp to reduce horizon stretch
    cloudUV = cloudUV * 0.14f + float2(time * speed, time * speed * 0.3f);
    float noise = skyFbm(cloudUV * density);
    float mask  = smoothstep(1.0f - coverage - 0.12f, 1.0f, noise);  // wider soft edge
    mask *= smoothstep(0.01f, 0.12f, viewDir.y);
    return mask;
}

// Upper-sky layer: flatter projection that stays dense near zenith.
static float cloudLayerHigh(float3 viewDir, float time, float speed, float density, float coverage) {
    if (viewDir.y < 0.30f || coverage < 0.001f) return 0.0f;
    float2 cloudUV = viewDir.xz / (viewDir.y + 0.45f);  // near-uniform scale near zenith
    cloudUV = cloudUV * 0.22f + float2(time * speed * 0.55f, -time * speed * 0.35f);
    float noise = skyFbm(cloudUV * density * 0.75f);
    float mask  = smoothstep(1.0f - coverage - 0.08f, 1.0f, noise);
    mask *= smoothstep(0.25f, 0.55f, viewDir.y) * 0.75f;  // fade in, cap at 75% opacity
    return mask;
}

// MARK: - Fragment

fragment float4 sky_fragment(
    SkyOut               in   [[stage_in]],
    constant SkyUniforms &sky [[buffer(0)]]
) {
    // Reconstruct world-space view direction from screen UV
    float2 ndc    = in.uv * 2.0f - 1.0f;
    float4 nearPt = sky.invViewProjection * float4(ndc, 0.0f, 1.0f);
    float4 farPt  = sky.invViewProjection * float4(ndc, 1.0f, 1.0f);
    nearPt /= nearPt.w;
    farPt  /= farPt.w;
    float3 viewDir = normalize(farPt.xyz - nearPt.xyz);

    float3 sunDir  = sky.sunDirectionAndIntensity.xyz;
    float  starVis = sky.cloudParams.w;
    float  coverage = sky.cloudParams.z;

    // Pre-compute moon occlusion so stars can be masked before they are added.
    float moonVis = clamp(-sunDir.y * 2.0f, 0.0f, 1.0f);
    float3 moonDir = -sunDir;
    float  cosM    = dot(viewDir, moonDir);
    // moonOcclude is NOT scaled by moonVis: the moon body is always opaque regardless
    // of how bright it appears — otherwise partial-night stars bleed through the disc.
    // The suppression zone starts wider than the disc edge so the anti-aliased rim is
    // also clean.
    float  moonOcclude = smoothstep(0.9978f, 0.9990f, cosM);

    // ── Simple vertical gradient ──────────────────────────────────────
    float  gradT  = clamp(viewDir.y * 0.5f + 0.5f, 0.0f, 1.0f);
    float3 colour = mix(sky.skyColorLow.rgb, sky.skyColorHigh.rgb, gradT);

    // Darken below the horizon for a natural ground-sky boundary
    float belowT = smoothstep(0.0f, -0.18f, viewDir.y);
    colour = mix(colour, sky.skyColorLow.rgb * 0.22f, belowT);

    // ── Stars — suppressed inside the moon disc ───────────────────────
    if (starVis > 0.001f) {
        float star = starField(viewDir, sky.cloudParams.x);
        colour += float3(star * starVis * 0.9f * (1.0f - moonOcclude));
    }

    // ── Clouds ────────────────────────────────────────────────────────
    if (coverage > 0.001f) {
        float cloudsLow  = cloudLayer(viewDir, sky.cloudParams.x, sky.cloudParams.y, 2.0f, coverage);
        float cloudsHigh = cloudLayerHigh(viewDir, sky.cloudParams.x, sky.cloudParams.y, 2.0f, coverage * 0.90f);
        float clouds     = clamp(cloudsLow + cloudsHigh * (1.0f - cloudsLow), 0.0f, 1.0f);
        float3 cloudTint = clamp(sky.skyColorLow.rgb * 1.8f + 0.12f, 0.0f, 1.0f);
        colour = mix(colour, cloudTint, clouds * 0.88f);
    }

    // ── Sun disc + glow ───────────────────────────────────────────────
    if (sunDir.y > -0.10f) {
        float cosG  = max(dot(viewDir, sunDir), 0.0f);
        float disc  = pow(cosG, sky.sunColorAndSize.w);
        float bloom = pow(cosG, 18.0f) * 0.35f;
        colour += sky.sunColorAndSize.rgb * (disc + bloom);
    }

    // ── Moon ──────────────────────────────────────────────────────────
    if (moonVis > 0.01f) {
        float  mDisc   = smoothstep(0.9988f, 0.9992f, cosM);
        float  mGlow   = pow(max(cosM, 0.0f), 32.0f) * 0.12f * moonVis;
        colour += float3(0.80f, 0.85f, 0.95f) * mGlow;
        colour  = mix(colour, float3(0.85f, 0.88f, 0.95f), mDisc * moonVis);
    }

    return float4(colour, 1.0f);
}
