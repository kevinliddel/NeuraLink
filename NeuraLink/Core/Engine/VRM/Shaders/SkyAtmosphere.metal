//
//  SkyAtmosphere.metal
//  NeuraLink
//
//  The atmosphere's three lookup tables (Hillaire 2020; SkyAtmosphere.swift):
//
//  - transmittance (256×64): how much light survives from any height along
//    any direction to space. Once, at launch.
//  - multiple scattering (32×32): light scattered more than once, which
//    fills the shadowed side of the sky and keeps twilight from going black.
//    Once, at launch.
//  - sky view (192×108): the whole sky seen from the ground, lit by the sun
//    and the moon, and in alpha how much of the low cloud layer shows
//    through the haze. Again whenever either light moves more than 0.1°.
//
//  The sky shader then only looks the view up (SkyShader.metal). The
//  clouds' noise is baked here too, once (sky_cloud_noise).
//
//  Created by Dedicatus on 28/10/2026.
//

#include "SkyAtmosphereCommon.metal"

// MARK: - Transmittance

kernel void sky_transmittance_lut(
    texture2d<half, access::write>  out [[texture(0)]],
    constant SkyAtmosphereParams   &a   [[buffer(0)]],
    uint2                           gid [[thread_position_in_grid]]
) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    // The inverse of skyTransmittanceCoord.
    float2 x = float2(gid) / float2(out.get_width() - 1, out.get_height() - 1);
    float bottom = a.radii.x, top = a.radii.y;
    float H   = sqrt(top * top - bottom * bottom);
    float rho = H * x.y;
    float r   = sqrt(rho * rho + bottom * bottom);
    float dMin = top - r, dMax = rho + H;
    float d   = dMin + x.x * (dMax - dMin);
    float mu  = d == 0.0f ? 1.0f : clamp((H * H - rho * rho - d * d) / (2.0f * r * d), -1.0f, 1.0f);

    float3 p   = float3(0.0f, r, 0.0f);
    float3 dir = float3(sqrt(max(0.0f, 1.0f - mu * mu)), mu, 0.0f);
    float  pathLength = max(skyRaySphere(p, dir, top), 0.0f);
    // Squared spacing: dense near the start, where the air is.
    const int steps = 40;
    float3 depth = 0.0f;
    float  previous = 0.0f;
    for (int i = 1; i <= steps; i++) {
        float next = pathLength * pow(float(i) / float(steps), 2.0f);
        float3 s = p + dir * (0.5f * (previous + next));
        depth += skyMedium(length(s) - bottom, a).extinction * (next - previous);
        previous = next;
    }
    out.write(half4(half3(exp(-depth)), 1.0h), gid);
}

// MARK: - Multiple scattering

// For one height and sun angle: the light reaching a point after the second
// scattering, from 64 directions around it, then every further order at
// once as a geometric series (Hillaire's ψ_ms = L₂ / (1 − f_ms)).
kernel void sky_multiscattering_lut(
    texture2d<half, access::write>  out           [[texture(0)]],
    texture2d<float>                transmittance [[texture(1)]],
    constant SkyAtmosphereParams   &a             [[buffer(0)]],
    uint2                           gid           [[thread_position_in_grid]]
) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 x = float2(gid) / float2(out.get_width() - 1, out.get_height() - 1);
    float bottom = a.radii.x, top = a.radii.y;
    float muSun = x.x * 2.0f - 1.0f;
    float r = bottom + clamp(x.y, 0.001f, 0.999f) * (top - bottom);
    float3 p   = float3(0.0f, r, 0.0f);
    float3 sun = float3(sqrt(max(0.0f, 1.0f - muSun * muSun)), muSun, 0.0f);
    const float isotropic = 1.0f / (4.0f * M_PI_F);

    float3 secondOrder = 0.0f;   // single-scattered light arriving, all directions
    float3 transfer    = 0.0f;   // the share of it scattered once more
    const int roots = 8, steps = 20;
    for (int i = 0; i < roots; i++) {
        for (int j = 0; j < roots; j++) {
            float azimuth = 2.0f * M_PI_F * (float(i) + 0.5f) / float(roots);
            float cosine  = 1.0f - 2.0f * (float(j) + 0.5f) / float(roots);
            float sine    = sqrt(max(0.0f, 1.0f - cosine * cosine));
            float3 dir = float3(cos(azimuth) * sine, cosine, sin(azimuth) * sine);
            float ground = skyRaySphere(p, dir, bottom);
            float tMax   = ground > 0.0f ? ground : max(skyRaySphere(p, dir, top), 0.0f);
            float dt     = tMax / float(steps);
            float3 throughput = 1.0f;
            for (int k = 0; k < steps; k++) {
                float3 s = p + dir * ((float(k) + 0.5f) * dt);
                float  h = length(s);
                float3 up = s / h;
                SkyMedium m = skyMedium(h - bottom, a);
                float3 scattering = m.rayleigh + m.mie;
                float  muS = dot(up, sun);
                float  lit = skyRaySphere(s + up * 0.01f, sun, bottom) >= 0.0f ? 0.0f : 1.0f;
                float3 sunlight = skyTransmittance(transmittance, h, muS, a) * lit;
                float3 stepT = exp(-m.extinction * dt);
                float3 integral = (1.0f - stepT) / m.extinction;
                secondOrder += throughput * sunlight * scattering * isotropic * integral;
                transfer    += throughput * scattering * integral;
                throughput  *= stepT;
            }
            if (ground > 0.0f) {
                float3 g  = p + dir * ground;
                float3 up = normalize(g);
                float muS = dot(up, sun);
                secondOrder += throughput * skyTransmittance(transmittance, length(g), muS, a)
                    * saturate(muS) * a.groundAlbedo.rgb / M_PI_F;
            }
        }
    }
    // Averaged over the sphere, each direction weighed by an isotropic phase:
    // 4π/64 · 1/4π.
    secondOrder /= float(roots * roots);
    transfer    /= float(roots * roots);
    out.write(half4(half3(secondOrder / (1.0f - transfer)), 1.0h), gid);
}

// MARK: - Sky view

// Light scattered toward the eye from one light along one step.
static inline float3 skyInScattered(
    float3 light, float3 up, float r, SkyMedium m, float rayleighPhase, float miePhase, float3 s,
    texture2d<float> transmittance, texture2d<float> multiple, constant SkyAtmosphereParams &a
) {
    float  muL = dot(up, light);
    float  lit = skyRaySphere(s + up * 0.01f, light, a.radii.x) >= 0.0f ? 0.0f : 1.0f;
    float3 direct = skyTransmittance(transmittance, r, muL, a) * lit
        * (m.rayleigh * rayleighPhase + m.mie * miePhase);
    return direct + skyMultipleScattering(multiple, r, muL, a) * (m.rayleigh + m.mie);
}

// How much of the low cloud layer shows through the air in front of it
// along `dir` [0, 1]: nearly all of it overhead, little on the horizon,
// 150 km away. Zero where the ground is in the way.
static inline float skyCloudHaze(
    float3 p, float3 dir, float ground, texture2d<float> transmittance, constant SkyAtmosphereParams &a
) {
    float shell = skyRaySphere(p, dir, a.radii.x + skyCloudHeight());
    if (ground > 0.0f || shell < 0.0f) return 0.0f;
    float3 q = p + dir * shell;
    float  r = length(q);
    // From the eye to space, over from the cloud to space.
    float3 toSpace = skyTransmittance(transmittance, length(p), dir.y, a);
    float3 beyond  = skyTransmittance(transmittance, r, dot(q / r, dir), a);
    return saturate(dot(toSpace / max(beyond, 1e-4f), float3(0.2126f, 0.7152f, 0.0722f)));
}

kernel void sky_view_lut(
    texture2d<half, access::write>  out           [[texture(0)]],
    texture2d<float>                transmittance [[texture(1)]],
    texture2d<float>                multiple      [[texture(2)]],
    constant SkyAtmosphereParams   &a             [[buffer(0)]],
    constant SkyViewParams         &view          [[buffer(1)]],
    uint2                           gid           [[thread_position_in_grid]]
) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float3 dir = skyViewDirection((float2(gid) + 0.5f) / float2(out.get_width(), out.get_height()));
    float bottom = a.radii.x;
    float3 p = float3(0.0f, bottom + a.radii.z, 0.0f);
    float ground = skyRaySphere(p, dir, bottom);
    float tMax   = ground > 0.0f ? ground : max(skyRaySphere(p, dir, a.radii.y), 0.0f);

    float3 sun = view.sun.xyz, moon = view.moon.xyz;
    float  g = a.mieExtinction.w;
    float  sunRayleigh  = skyRayleighPhase(dot(dir, sun)),  sunMie  = skyMiePhase(dot(dir, sun), g);
    float  moonRayleigh = skyRayleighPhase(dot(dir, moon)), moonMie = skyMiePhase(dot(dir, moon), g);
    bool   moonLit = view.moon.w > 0.0f;

    // Squared spacing: dense near the eye, where the air is thickest.
    const int steps = 32;
    float3 luminance = 0.0f, throughput = 1.0f;
    float  previous = 0.0f;
    for (int i = 1; i <= steps; i++) {
        float next = tMax * pow(float(i) / float(steps), 2.0f);
        float dt   = next - previous;
        float3 s   = p + dir * (0.5f * (previous + next));
        previous   = next;
        float  h   = length(s);
        float3 up  = s / h;
        SkyMedium m = skyMedium(h - bottom, a);
        float3 scattered = skyInScattered(sun, up, h, m, sunRayleigh, sunMie, s, transmittance, multiple, a)
            * view.sun.w;
        if (moonLit) {
            scattered += skyInScattered(moon, up, h, m, moonRayleigh, moonMie, s, transmittance, multiple, a)
                * view.moon.w;
        }
        float3 stepT = exp(-m.extinction * dt);
        luminance  += throughput * scattered * (1.0f - stepT) / m.extinction;
        throughput *= stepT;
    }
    out.write(half4(half3(luminance), half(skyCloudHaze(p, dir, ground, transmittance, a))), gid);
}

// MARK: - Clouds

static inline float skyCloudHash(uint2 cell, uint octave) {
    uint h = cell.x * 1597334673u ^ cell.y * 3812015801u ^ octave * 2798796415u;
    h = (h ^ (h >> 16)) * 0x7feb352du;
    h = (h ^ (h >> 15)) * 0x846ca68bu;
    return float(h ^ (h >> 16)) * (1.0f / 4294967295.0f);
}

// The clouds' shape, baked once (256², mipmapped): value noise in five
// octaves, from 4 to 64 cells across, each wrapping at the edges so the
// texture tiles without a seam. The sky reads it twice a pixel where six
// octaves of hashing per layer used to run.
kernel void sky_cloud_noise(
    texture2d<half, access::write> out [[texture(0)]],
    uint2                          gid [[thread_position_in_grid]]
) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 x = (float2(gid) + 0.5f) / float2(out.get_width(), out.get_height());
    float value = 0.0f, amplitude = 0.5f;
    uint  cells = 4;
    for (uint octave = 0; octave < 5; octave++) {
        float2 g = x * float(cells);
        uint2  i = uint2(g);
        float2 f = g - floor(g);
        float2 u = f * f * (3.0f - 2.0f * f);
        uint2  j = (i + 1) % cells;
        float  a = skyCloudHash(i, octave), b = skyCloudHash(uint2(j.x, i.y), octave);
        float  c = skyCloudHash(uint2(i.x, j.y), octave), d = skyCloudHash(j, octave);
        value += amplitude * mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
        cells *= 2;
        amplitude *= 0.5f;
    }
    out.write(half4(half(value)), gid);
}
