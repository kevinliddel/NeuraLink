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
//    and the moon. Again whenever either moves more than 0.1°.
//
//  The sky shader then only looks the view up (SkyShader.metal).
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
    out.write(half4(half3(luminance), 1.0h), gid);
}
