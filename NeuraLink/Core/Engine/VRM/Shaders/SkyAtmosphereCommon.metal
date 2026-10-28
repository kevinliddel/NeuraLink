//
//  SkyAtmosphereCommon.metal
//  NeuraLink
//
//  What the atmosphere's lookup tables (SkyAtmosphere.metal) and the sky
//  that reads them (SkyShader.metal) share: the medium, the phase
//  functions and the tables' layouts. Hillaire 2020; see SkyAtmosphere.swift.
//
//  Created by Dedicatus on 28/10/2026.
//

#include <metal_stdlib>
using namespace metal;

// Must match SkyAtmosphereParams in SkyAtmosphere.swift (96 bytes).
struct SkyAtmosphereParams {
    float4 rayleigh;        // rgb = scattering per km, w = scale height (km)
    float4 mieScattering;   // rgb = scattering per km, w = scale height (km)
    float4 mieExtinction;   // rgb = extinction per km, w = phase asymmetry g
    float4 ozone;           // rgb = absorption per km, w = layer peak height (km)
    float4 groundAlbedo;    // rgb = albedo, w = ozone layer half width (km)
    float4 radii;           // x = ground, y = top of the atmosphere, z = camera height (km)
};

// Must match SkyViewParams in SkyAtmosphere.swift.
struct SkyViewParams {
    float4 sun;             // xyz = toward the sun, w = its light, exposure folded in
    float4 moon;            // xyz = toward the moon, w = its light
};

struct SkyMedium {
    float3 rayleigh;        // scattering
    float3 mie;             // scattering
    float3 extinction;      // everything that takes light out
};

static inline SkyMedium skyMedium(float height, constant SkyAtmosphereParams &a) {
    float mieDensity   = exp(-height / a.mieScattering.w);
    float ozoneDensity = max(0.0f, 1.0f - abs(height - a.ozone.w) / a.groundAlbedo.w);
    SkyMedium m;
    m.rayleigh   = a.rayleigh.rgb * exp(-height / a.rayleigh.w);
    m.mie        = a.mieScattering.rgb * mieDensity;
    m.extinction = m.rayleigh + a.mieExtinction.rgb * mieDensity + a.ozone.rgb * ozoneDensity;
    return m;
}

static inline float skyRayleighPhase(float cosine) {
    return 3.0f / (16.0f * M_PI_F) * (1.0f + cosine * cosine);
}

// Cornette–Shanks.
static inline float skyMiePhase(float cosine, float g) {
    float g2 = g * g;
    return 3.0f / (8.0f * M_PI_F) * (1.0f - g2) * (1.0f + cosine * cosine)
        / ((2.0f + g2) * pow(1.0f + g2 - 2.0f * g * cosine, 1.5f));
}

// Distance along `d` from `p` to the sphere of `radius` about the planet's
// centre: the nearest crossing ahead, or −1 when there is none.
static inline float skyRaySphere(float3 p, float3 d, float radius) {
    float b = dot(p, d);
    float c = dot(p, p) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0f) return -1.0f;
    float s = sqrt(disc);
    if (-b - s >= 0.0f) return -b - s;
    if (-b + s >= 0.0f) return -b + s;
    return -1.0f;
}

// Texel centres span [0, 1] exactly: texel 0 holds x = 0, the last x = 1.
static inline float2 skyLutUV(float2 x, float2 size) {
    return (x * (size - 1.0f) + 0.5f) / size;
}

// MARK: - Transmittance table (Bruneton's layout)

// (height r from the planet's centre, cosine of the zenith angle) → [0, 1]².
// Covers the rays that reach space; a ray into the ground is in the planet's
// shadow, which the caller tests.
static inline float2 skyTransmittanceCoord(float r, float mu, constant SkyAtmosphereParams &a) {
    float bottom = a.radii.x, top = a.radii.y;
    float H   = sqrt(top * top - bottom * bottom);
    float rho = sqrt(max(0.0f, r * r - bottom * bottom));
    float d   = max(0.0f, -r * mu + sqrt(max(r * r * (mu * mu - 1.0f) + top * top, 0.0f)));
    float dMin = top - r, dMax = rho + H;
    return float2((d - dMin) / max(dMax - dMin, 1e-4f), rho / H);
}

static inline float3 skyTransmittance(
    texture2d<float> lut, float r, float mu, constant SkyAtmosphereParams &a
) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float2 size = float2(lut.get_width(), lut.get_height());
    return lut.sample(linear, skyLutUV(skyTransmittanceCoord(r, mu, a), size), level(0)).rgb;
}

// MARK: - Multiple-scattering table

// (cosine of the sun's zenith angle, height) → [0, 1]².
static inline float3 skyMultipleScattering(
    texture2d<float> lut, float r, float muSun, constant SkyAtmosphereParams &a
) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float2 x = float2(muSun * 0.5f + 0.5f, (r - a.radii.x) / (a.radii.y - a.radii.x));
    float2 size = float2(lut.get_width(), lut.get_height());
    return lut.sample(linear, skyLutUV(saturate(x), size), level(0)).rgb;
}

// MARK: - Sky-view table

// u: around the horizon, azimuth from +X toward +Z, the seam at −X.
// v: from straight down to straight up, squeezed toward the horizon, where
// the sky changes fastest. Texel centres: uv = (texel + ½) / size.
static inline float3 skyViewDirection(float2 uv) {
    float azimuth   = (uv.x - 0.5f) * 2.0f * M_PI_F;
    float s         = uv.y * 2.0f - 1.0f;
    float elevation = sign(s) * s * s * 0.5f * M_PI_F;
    return float3(cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth));
}

static inline float2 skyViewUV(float3 d) {
    float azimuth   = atan2(d.z, d.x);
    float elevation = asin(clamp(d.y, -1.0f, 1.0f));
    float s         = sign(elevation) * sqrt(abs(elevation) / (0.5f * M_PI_F));
    return float2(azimuth / (2.0f * M_PI_F) + 0.5f, s * 0.5f + 0.5f);
}
