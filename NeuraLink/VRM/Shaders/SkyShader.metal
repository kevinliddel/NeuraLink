//
//  SkyShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//
//  Physically-inspired sky: Rayleigh+Mie scattering, sun disc, star field, dome clouds.

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms

struct SkyUniforms {
    float4x4 invViewProjection;         // NDC → world-space ray cast
    float4   sunDirectionAndIntensity;  // xyz = toward-sun unit vector, w = intensity
    float4   sunColorAndSize;           // xyz = sun disc colour, w = cos(half-angle)
    float4   cloudColorAndCoverage;     // xyz = cloud tint, w = coverage [0,1]
    float4   cloudParams;               // x = elapsed time, y = scroll speed, z = density, w = star vis
    float4   turbidityAndFlags;         // x = turbidity [2–10]
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
    out.uv = pos[vid] * 0.5f + 0.5f;   // uv.y = 0 bottom, 1 top
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
    for (int i = 0; i < 5; i++) { val += amp * skyValueNoise(p); p *= 2.1f; amp *= 0.5f; }
    return val;
}

// MARK: - Atmospheric scattering

/// Simplified Rayleigh + Mie scattering producing realistic sky colours.
static float3 atmosphericSky(float3 viewDir, float3 sunDir, float turbidity) {
    float sunY         = sunDir.y;
    float dayFactor    = smoothstep(-0.10f, 0.20f, sunY);
    float sunsetStrength = clamp(1.0f - abs(sunY) * 3.5f, 0.0f, 1.0f)
                           * (sunY > -0.05f ? 1.0f : 0.0f);

    // Angular quantities
    float cosGamma = dot(viewDir, sunDir);           // angle to sun
    float viewElev = viewDir.y;                      // elevation of view ray

    // ------------------------------------------------------------------
    // Rayleigh colour bands
    float3 zenithDay    = float3(0.06f, 0.28f, 0.76f);
    float3 horizonDay   = float3(0.55f, 0.76f, 1.00f);
    float3 sunsetZenith = float3(0.18f, 0.14f, 0.38f);
    float3 sunsetHorizon= float3(0.88f, 0.40f, 0.08f);
    float3 nightSky     = float3(0.01f, 0.01f, 0.04f);

    // Zenith-to-horizon vertical gradient
    float horizT = clamp(viewElev / 0.5f, 0.0f, 1.0f);
    float3 daySky = mix(horizonDay, zenithDay, pow(horizT, 0.6f));

    // Sunset warm colouring: strongest near horizon, toward-sun side
    float sunSideBoost = smoothstep(-0.4f, 1.0f, cosGamma);
    float3 sunsetSky   = mix(sunsetHorizon, sunsetZenith, horizT);
    daySky = mix(daySky, sunsetSky, sunsetStrength * sunSideBoost * 0.85f);

    // Atmospheric haze increases with turbidity
    float haze = clamp((turbidity - 2.0f) / 8.0f, 0.0f, 1.0f);
    daySky = mix(daySky, daySky * float3(1.08f, 0.88f, 0.68f), haze * dayFactor * 0.3f);

    // ------------------------------------------------------------------
    // Mie forward-scattering glow (soft corona, not the disc itself)
    float mie = pow(max(cosGamma, 0.0f), 5.0f) * 0.18f;
    float3 mieCol = mix(float3(0.90f, 0.50f, 0.12f), float3(0.90f, 0.82f, 0.68f), dayFactor);
    daySky += mieCol * mie * dayFactor;

    // ------------------------------------------------------------------
    // Ground half-sphere (below horizon)
    float3 groundCol = mix(float3(0.06f, 0.05f, 0.04f) * dayFactor,
                           daySky * 0.30f, 0.4f);
    float belowBlend = smoothstep(0.0f, -0.12f, viewElev);
    daySky = mix(daySky, groundCol, belowBlend);

    // ------------------------------------------------------------------
    // Day ↔ night blend
    return mix(nightSky, daySky, dayFactor);
}

// MARK: - Sun disc

static float sunDisc(float3 viewDir, float3 sunDir, float cosHalfAngle) {
    float cosA = dot(viewDir, sunDir);
    return smoothstep(cosHalfAngle - 0.0015f, cosHalfAngle + 0.0015f, cosA);
}

// MARK: - Stars

static float starField(float3 viewDir, float time) {
    // Only visible in upper hemisphere; tiny random dots.
    if (viewDir.y < 0.0f) return 0.0f;
    float2 uv = float2(atan2(viewDir.x, viewDir.z) * (0.5f / M_PI_F) + 0.5f,
                       acos(viewDir.y) * (1.0f / M_PI_F));
    float2 cell = floor(uv * 250.0f);
    float rnd   = skyHash(cell + floor(time * 0.01f));   // slow twinkle
    float bright = step(0.96f, rnd);
    float2 local = fract(uv * 250.0f) - 0.5f;
    float dist   = length(local);
    return bright * smoothstep(0.22f, 0.0f, dist);
}

// MARK: - Dome-projected clouds

static float cloudLayer(float3 viewDir, float time, float speed, float density, float coverage) {
    if (viewDir.y < 0.02f || coverage < 0.001f) return 0.0f;

    // Project view ray onto cloud dome (y = 1 normalised plane)
    float2 cloudUV = viewDir.xz / (viewDir.y + 0.05f);
    cloudUV = cloudUV * 0.18f + float2(time * speed, time * speed * 0.3f);

    float noise = skyFbm(cloudUV * density);
    float mask  = smoothstep(1.0f - coverage, 1.0f, noise);

    // Fade out near horizon
    mask *= smoothstep(0.02f, 0.20f, viewDir.y);
    return mask;
}

// MARK: - Fragment

fragment float4 sky_fragment(
    SkyOut               in  [[stage_in]],
    constant SkyUniforms &sky [[buffer(0)]]
) {
    // ----------------------------------------------------------------
    // Reconstruct world-space view direction from screen UV
    float2 ndc = in.uv * 2.0f - 1.0f;
    float4 nearPt = sky.invViewProjection * float4(ndc, 0.0f, 1.0f);
    float4 farPt  = sky.invViewProjection * float4(ndc, 1.0f, 1.0f);
    nearPt /= nearPt.w;
    farPt  /= farPt.w;
    float3 viewDir = normalize(farPt.xyz - nearPt.xyz);

    float3 sunDir      = sky.sunDirectionAndIntensity.xyz;
    float  sunIntensity= sky.sunDirectionAndIntensity.w;
    float  turbidity   = sky.turbidityAndFlags.x;
    float  starVis     = sky.cloudParams.w;

    // ----------------------------------------------------------------
    // Base atmospheric sky colour
    float3 colour = atmosphericSky(viewDir, sunDir, turbidity);

    // ----------------------------------------------------------------
    // Stars (night only, upper hemisphere)
    if (starVis > 0.001f) {
        float star = starField(viewDir, sky.cloudParams.x);
        colour += float3(star * starVis * 0.9f);
    }

    // ----------------------------------------------------------------
    // Cloud layer
    float coverage = sky.cloudColorAndCoverage.w;
    if (coverage > 0.001f) {
        float clouds = cloudLayer(
            viewDir,
            sky.cloudParams.x, sky.cloudParams.y,
            sky.cloudParams.z, coverage
        );
        colour = mix(colour, sky.cloudColorAndCoverage.rgb, clouds * 0.88f);
    }

    // ----------------------------------------------------------------
    // Sun disc + wide glow (only above horizon)
    if (sunDir.y > -0.10f && sunIntensity > 0.01f) {
        // Wide Mie corona is already in atmosphericSky; add a tighter bloom here
        float cosGamma = dot(viewDir, sunDir);
        float bloom    = pow(max(cosGamma, 0.0f), 64.0f) * 0.6f;
        colour += sky.sunColorAndSize.rgb * bloom * sunIntensity;

        // Hard disc
        float disc = sunDisc(viewDir, sunDir, sky.sunColorAndSize.w);
        if (disc > 0.0f) {
            float3 discCol = sky.sunColorAndSize.rgb * (1.5f + sunIntensity);
            colour = mix(colour, discCol, disc);
        }
    }

    // Moon disc (opposite to sun, visible at night)
    float moonVis = clamp(-sunDir.y * 2.0f, 0.0f, 1.0f);
    if (moonVis > 0.01f) {
        float3 moonDir = -sunDir;
        float cosM  = dot(viewDir, moonDir);
        float mDisc = smoothstep(0.9988f, 0.9992f, cosM);  // ~2.5° radius
        float mGlow = pow(max(cosM, 0.0f), 32.0f) * 0.12f * moonVis;
        colour += float3(0.80f, 0.85f, 0.95f) * mGlow;
        colour  = mix(colour, float3(0.85f, 0.88f, 0.95f), mDisc * moonVis);
    }

    return float4(colour, 1.0f);
}
