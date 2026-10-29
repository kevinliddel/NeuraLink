//
//  SkyShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//
//  The sky: the atmosphere looked up from its sky-view table
//  (SkyAtmosphere.metal), the night's own glow under it, then two layers of
//  clouds lit through the same atmosphere, the sun disc, a moon lit from the
//  sun's side, and stars that turn with the sky — a procedural faint field
//  here, the catalogue's bright ones as sprites (sky_star_vertex /
//  sky_star_fragment).

#include "SkyAtmosphereCommon.metal"

// MARK: - Uniforms (must match SkyUniformsData in Swift, 256 bytes)

struct SkyUniforms {
    float4x4 invViewProjection;         // NDC → world-space ray cast
    float4   sunDirectionAndIntensity;  // xyz = toward-sun unit vector, w = intensity
    float4   sunColorAndSize;           // xyz = sun disc colour, w = disc exponent
    float4   nightGlowLow;              // xyz = the night's glow at the horizon, w = rain [0, 1]
    float4   nightGlowHigh;             // xyz = at the zenith, w unused
    float4   cloudParams;               // x = elapsed time, y = scroll speed, z = coverage, w = star vis
    float4   moonDirectionAndPhase;     // xyz = toward-moon unit vector, w = lit fraction
    float4   bodyParams;                // x = moon angular radius (rad), z = moon brightness
    float3x3 starRotation;              // star catalogue (J2000 equatorial) → world
    float4   moonEdges;                 // cos of the moon's angular radius × 1.48, 1, 1.03, 0.97
    float4   detail;                    // x = cloud layers drawn (2, or 1 on a hot phone)
};

// One catalogue star (must match SkyStarData in Swift, 32 bytes).
struct SkyStar {
    float4 directionAndMagnitude;       // xyz = J2000 equatorial unit vector, w = V magnitude
    float4 color;                       // rgb = tint from B−V
};

// MARK: - Vertex — fullscreen triangle (no vertex buffer needed)

struct SkyOut {
    float4 position [[position]];
    float3 ray;     // world-space view ray, not normalised
};

// The view ray is worked out at the three corners and interpolated: from
// near plane to far plane it is affine in screen space for a perspective
// or orthographic camera, so this is exact, and the fragment only
// normalises it.
vertex SkyOut sky_vertex(
    uint                 vid [[vertex_id]],
    constant SkyUniforms &sky [[buffer(0)]]
) {
    constexpr float2 pos[3] = {
        float2(-1.0f, -3.0f),
        float2(-1.0f,  1.0f),
        float2( 3.0f,  1.0f)
    };
    float4 nearPt = sky.invViewProjection * float4(pos[vid], 0.0f, 1.0f);
    float4 farPt  = sky.invViewProjection * float4(pos[vid], 1.0f, 1.0f);
    SkyOut out;
    out.position = float4(pos[vid], 0.9999f, 1.0f);
    out.ray = farPt.xyz / farPt.w - nearPt.xyz / nearPt.w;
    return out;
}

// MARK: - Noise helpers

// An integer hash, [0, 1]. Integer arithmetic gives the same answer on
// every GPU and compiler; a sine-based hash doesn't (the moon's seas moved
// between builds), and costs more.
static float skyCellHash(uint2 cell, uint salt) {
    uint h = cell.x * 1597334673u ^ cell.y * 3812015801u ^ salt * 2798796415u;
    h = (h ^ (h >> 16)) * 0x7feb352du;
    h = (h ^ (h >> 15)) * 0x846ca68bu;
    return float(h ^ (h >> 16)) * (1.0f / 4294967295.0f);
}

static float skyValueNoise(float2 p) {
    float2 f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    uint2  i = uint2(int2(floor(p)) + 4096);   // kept positive for the cast
    return mix(mix(skyCellHash(i, 0u),               skyCellHash(i + uint2(1, 0), 0u), u.x),
               mix(skyCellHash(i + uint2(0, 1), 0u), skyCellHash(i + uint2(1, 1), 0u), u.x), u.y);
}

// MARK: - Stars

// Direction through (u, v) ∈ [−1, 1]² on cube face `face` (+x −x +y −y +z −z).
static float3 cubeFaceDirection(int face, float2 uv) {
    switch (face) {
        case 0:  return normalize(float3( 1.0f, uv.x, uv.y));
        case 1:  return normalize(float3(-1.0f, uv.x, uv.y));
        case 2:  return normalize(float3(uv.x,  1.0f, uv.y));
        case 3:  return normalize(float3(uv.x, -1.0f, uv.y));
        case 4:  return normalize(float3(uv.x, uv.y,  1.0f));
        default: return normalize(float3(uv.x, uv.y, -1.0f));
    }
}

// The faint stars, in the stars' own frame (`d` = equatorial unit vector) so
// they turn with the catalogue's. A grid on the faces of a cube holds at
// most one star a cell, kept inside it; the chance of one follows the cell's
// solid angle, so the cube's corners are no denser than its faces. Each is a
// round dot of a set ANGULAR size, measured to its true direction.
static float faintStars(float3 d) {
    float3 a = abs(d);
    int face;
    float2 uv;
    if (a.x >= a.y && a.x >= a.z) { face = d.x > 0.0f ? 0 : 1; uv = d.yz / a.x; }
    else if (a.y >= a.z)          { face = d.y > 0.0f ? 2 : 3; uv = d.xz / a.y; }
    else                          { face = d.z > 0.0f ? 4 : 5; uv = d.xy / a.z; }
    const float cells = 80.0f;
    float2 grid  = (uv * 0.5f + 0.5f) * cells;
    float2 cell  = floor(grid);
    uint2  key   = uint2(cell);
    uint   salt  = uint(face) * 3u;
    float2 centre = (cell + 0.5f) / cells * 2.0f - 1.0f;
    float chance = 0.07f * pow(1.0f + dot(centre, centre), -1.5f);
    float rnd    = skyCellHash(key, salt);
    if (rnd > chance) return 0.0f;
    float2 jitter = float2(skyCellHash(key, salt + 1u), skyCellHash(key, salt + 2u)) * 0.5f + 0.25f;
    float3 star   = cubeFaceDirection(face, (cell + jitter) / cells * 2.0f - 1.0f);
    float angle   = length(cross(d, star));       // sin θ ≈ θ this close
    float bright  = rnd / chance;                 // 0…1 among the cells that hold one
    float radius  = 0.0015f + 0.0013f * bright;   // radians
    return (1.0f - smoothstep(radius * 0.3f, radius, angle)) * (0.22f + 0.5f * bright * bright);
}

// MARK: - Clouds

// Two layers, each a shell around the planet: the clouds run on to a real
// horizon, smaller with distance, and fade into the haze in front of them
// rather than at a fixed height. Their shape is the noise baked once
// (sky_cloud_noise), read twice a pixel, the second time finer and turned,
// to fray the edges. They are lit by the sun, or by the moon after dusk,
// through the atmosphere: white by day, orange to red at sunset, grey-blue
// at night, silver around a full moon.
struct CloudLayer {
    float  height;      // above the ground, km
    float  thickness;   // km: how far a low light runs through it
    float  scale;       // noise cells per km
    float2 drift;       // noise cells a second, per unit of scroll speed
    float  start;       // noise above (start − coverage) is cloud…
    float  width;       // …growing dense over this much more
    float  opacity;     // at most
    float  absorption;  // how dark it grows, per unit of thickness toward the light
};

// Heaped clouds low, with edges, about two fifths of the sky at the day's
// coverage and all of it in the rain; a thin veil high, its cells the size
// the old dome's were at the zenith.
constant CloudLayer kCloudLow  = { skyCloudHeight(), 1.0f, 0.22f, float2(2.82f, 0.85f), 1.0f, 0.18f, 1.0f, 0.9f };
constant CloudLayer kCloudHigh = { 6.0f, 0.5f, 0.039f, float2(0.825f, -0.525f), 0.92f, 0.55f, 0.75f, 0.5f };

constexpr sampler kCloudTiled(filter::linear, mip_filter::linear, address::repeat);

// The baked noise at `p` (in cells of its coarsest octave, four to the
// texture), and a finer read turned against it.
static float cloudNoise(texture2d<float> noise, float2 p, float2 dx, float2 dy) {
    const float2x2 turn = float2x2(float2(2.96f, 2.22f), float2(-2.22f, 2.96f));   // ×3.7, 37°
    float coarse = noise.sample(kCloudTiled, p * 0.25f, gradient2d(dx * 0.25f, dy * 0.25f)).r;
    float fine   = noise.sample(kCloudTiled, turn * p * 0.25f, gradient2d(turn * dx * 0.25f, turn * dy * 0.25f)).r;
    return coarse + (fine - 0.484f) * 0.22f;
}

static float cloudDensity(float n, float coverage, constant CloudLayer &layer) {
    return smoothstep(layer.start - coverage, layer.start - coverage + layer.width, n);
}

// How thick the cloud is: like its density but going on past opaque, so a
// heavy cloud's core, and a rain deck's, is darker than its edges.
static float cloudThickness(float n, float coverage, constant CloudLayer &layer) {
    return clamp((n - layer.start + coverage) / layer.width, 0.0f, 3.0f);
}

// Where `d` meets `layer`: planet-centred, km.
static float3 cloudPoint(float3 d, constant CloudLayer &layer, constant SkyAtmosphereParams &a) {
    float3 eye = float3(0.0f, a.radii.x + a.radii.z, 0.0f);
    return eye + d * max(skyRaySphere(eye, d, a.radii.x + layer.height), 0.0f);
}

// The noise under `q`, drifting with the wind.
static float2 cloudPosition(float3 q, constant CloudLayer &layer, constant SkyUniforms &sky) {
    return q.xz * layer.scale + layer.drift * (sky.cloudParams.x * sky.cloudParams.y);
}

// `light` (xyz toward it, w its strength) as it reaches the cloud at `q`:
// reddened by the air on its way, none once the planet is in between.
static float3 cloudLightArriving(
    float3 q, float4 light, texture2d<float> transmittance, constant SkyAtmosphereParams &a
) {
    if (light.w <= 0.0f || skyRaySphere(q, light.xyz, a.radii.x) >= 0.0f) return 0.0f;
    float r = length(q);
    return skyTransmittance(transmittance, r, dot(q / r, light.xyz), a) * light.w;
}

// The share of that light the low layer lets through to its underside: its
// own thickness, and two reads toward the light, farther the lower the
// light, so a low sun lights the sides facing it and leaves the far ones
// dark.
static float cloudThrough(
    float thickness, float2 p, float3 light, float coverage, texture2d<float> noise, float2 dx, float2 dy
) {
    constant CloudLayer &layer = kCloudLow;
    float  across = length(light.xz);
    float  run    = min(layer.thickness * across / max(light.y, 0.1f), 3.0f) * layer.scale;
    float2 toward = across > 1e-4f ? light.xz / across * run : float2(0.0f);
    gradient2d footprint(dx * 0.25f, dy * 0.25f);
    float near = cloudThickness(noise.sample(kCloudTiled, (p + toward * 0.35f) * 0.25f, footprint).r, coverage, layer);
    float far  = cloudThickness(noise.sample(kCloudTiled, (p + toward) * 0.25f, footprint).r, coverage, layer);
    return exp(-layer.absorption * (thickness + near + far));
}

// A cloud's light toward the eye, before the grade: what comes through it,
// scattered mostly forward (Henyey–Greenstein, g = 0.6, against an even
// share), so it is lined with silver where thin toward the light; the
// ground's light from below; and the sky's on its shadowed side.
static float3 cloudRadiance(float3 arriving, float through, float cosine, float upward, float3 ambient) {
    const float g = 0.6f;
    float forward = (1.0f - g * g) / pow(1.0f + g * g - 2.0f * g * cosine, 1.5f);
    return arriving * (through * (0.15f + 0.04f * forward) + upward * 0.02f) + ambient;
}

// How much the layers hide along `d`, for the catalogue stars: a vertex
// has no footprint to choose a mip level by, so a fixed soft one.
static float cloudCover(float3 d, constant SkyUniforms &sky, texture2d<float> noise, constant SkyAtmosphereParams &a) {
    float coverage = sky.cloudParams.z;
    if (coverage <= 0.001f || d.y < -0.02f) return 0.0f;
    float2 low  = cloudPosition(cloudPoint(d, kCloudLow, a), kCloudLow, sky);
    float  lowCover = cloudDensity(noise.sample(kCloudTiled, low * 0.25f, level(1.0f)).r, coverage, kCloudLow);
    if (sky.detail.x < 1.5f) return lowCover;
    float2 high = cloudPosition(cloudPoint(d, kCloudHigh, a), kCloudHigh, sky);
    float  highCover = cloudDensity(noise.sample(kCloudTiled, high * 0.25f, level(1.0f)).r, coverage * 0.9f, kCloudHigh)
        * kCloudHigh.opacity;
    return 1.0f - (1.0f - lowCover) * (1.0f - highCover);
}

// Moonlight washing the stars out [0, 1]: the moon's brightness while it is
// up, and more of it near the moon.
static float moonGlare(float cosM, float3 moonDir, constant SkyUniforms &sky) {
    float up = smoothstep(-0.02f, 0.06f, moonDir.y);
    return sky.bodyParams.z * up * (0.45f + 0.55f * smoothstep(0.8f, 0.995f, cosM));
}

// MARK: - The atmosphere's colour

// Rain's overcast: the colour drained, the sky darker, as bright as before
// otherwise, so a rainy night stays night.
static float3 skyOvercast(float3 colour, float rain) {
    float luma = dot(colour, float3(0.2126f, 0.7152f, 0.0722f));
    return mix(colour, luma * float3(0.95f, 1.0f, 1.06f), rain * 0.7f) * (1.0f - rain * 0.28f);
}

// The atmosphere along `d` as shown, from its sky-view radiance, with the
// night's own glow (airglow, starlight) under twilight: deep blue, a little
// brighter overhead, darker below the horizon.
static float3 skyAtmosphere(float3 radiance, float3 d, constant SkyUniforms &sky) {
    float3 glow = mix(sky.nightGlowLow.rgb, sky.nightGlowHigh.rgb, saturate(d.y * 0.5f + 0.5f));
    return skyGrade(radiance) + glow * mix(1.0f, 0.22f, 1.0f - smoothstep(-0.18f, 0.0f, d.y));
}

// MARK: - Fragment

fragment float4 sky_fragment(
    SkyOut                        in            [[stage_in]],
    constant SkyUniforms         &sky           [[buffer(0)]],
    constant SkyViewParams       &lights        [[buffer(1)]],
    constant SkyAtmosphereParams &a             [[buffer(2)]],
    texture2d<float>              skyView       [[texture(0)]],
    texture2d<float>              transmittance [[texture(1)]],
    texture2d<float>              noise         [[texture(2)]]
) {
    float3 viewDir = normalize(in.ray);

    float3 sunDir  = sky.sunDirectionAndIntensity.xyz;
    float3 moonDir = sky.moonDirectionAndPhase.xyz;
    float  moonRadius = sky.bodyParams.x;
    float  starVis = sky.cloudParams.w;

    // The moon is drawn whenever it is up, by day too, part-transparent
    // against a bright sky; its glow only at night.
    float night   = 1.0f - smoothstep(-0.10f, 0.05f, sunDir.y);
    float moonVis = smoothstep(-0.02f, 0.03f, moonDir.y) * mix(0.7f, 1.0f, night);
    float  cosM    = dot(viewDir, moonDir);

    // ── The atmosphere ────────────────────────────────────────────────
    constexpr sampler around(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float4 behind = skyView.sample(around, skyViewUV(viewDir));   // a = the haze before the clouds
    float3 colour = skyAtmosphere(behind.rgb, viewDir, sky);

    // ── Faint stars — turning with the sky, hidden behind the moon ────
    if (starVis > 0.001f && viewDir.y > 0.0f) {
        float star = faintStars(transpose(sky.starRotation) * viewDir);
        float glare = moonGlare(cosM, moonDir, sky);
        // The moon hides the stars behind it however faint it looks, over a
        // rim a little wider than its disc so the anti-aliased edge is clean.
        float moonOcclude = smoothstep(sky.moonEdges.x, sky.moonEdges.y, cosM);
        colour += float3(star * starVis * (1.0f - 0.7f * glare) * (1.0f - moonOcclude));
    }

    // ── Clouds ────────────────────────────────────────────────────────
    float  coverage = sky.cloudParams.z;
    float  clouds = 0.0f;   // how much of what is behind them they hide
    // Coverage is the same for every pixel: no clouds, no cloud work. Within
    // it, where each layer's noise lies under the pixel and its footprint
    // for the mip level come before any per-pixel branch, so the
    // derivatives hold.
    if (coverage > 0.001f) {
        bool   bothLayers = sky.detail.x > 1.5f;
        float3 lowPoint  = cloudPoint(viewDir, kCloudLow, a);
        float2 low   = cloudPosition(lowPoint, kCloudLow, sky);
        float2 lowDx = dfdx(low), lowDy = dfdy(low);
        float3 highPoint = 0.0f;
        float2 high = 0.0f, highDx = 0.0f, highDy = 0.0f;
        if (bothLayers) {
            highPoint = cloudPoint(viewDir, kCloudHigh, a);
            high   = cloudPosition(highPoint, kCloudHigh, sky);
            highDx = dfdx(high);
            highDy = dfdy(high);
        }
        if (viewDir.y > -0.02f) {
            // The sun lights them until it has set for them too, a little
            // after it has for the ground; the moon after that.
            float4 key      = lights.sun.y > -0.05f ? lights.sun : lights.moon;
            float  cosine   = dot(viewDir, key.xyz);
            float  upward   = saturate(key.y);
            float3 zenith   = skyView.sample(around, float2(0.5f, 1.0f)).rgb;
            float3 ambient  = (behind.rgb + zenith) * 0.3f;
            float3 glow     = sky.nightGlowHigh.rgb * 1.25f;

            float highDensity = bothLayers
                ? cloudDensity(cloudNoise(noise, high, highDx, highDy), coverage * 0.9f, kCloudHigh) : 0.0f;
            if (highDensity > 0.0f) {
                float3 arriving = cloudLightArriving(highPoint, key, transmittance, a);
                float  through  = exp(-kCloudHigh.absorption * highDensity * 2.0f);
                float3 shown    = skyGrade(cloudRadiance(arriving, through, cosine, upward, ambient)) + glow;
                clouds = highDensity * kCloudHigh.opacity * pow(behind.a, 1.3f);
                colour = mix(colour, shown, clouds);
            }
            float lowNoise   = cloudNoise(noise, low, lowDx, lowDy);
            float lowDensity = cloudDensity(lowNoise, coverage, kCloudLow);
            if (lowDensity > 0.0f) {
                float3 arriving = cloudLightArriving(lowPoint, key, transmittance, a);
                float  through  = all(arriving == 0.0f) ? 0.0f : cloudThrough(
                    cloudThickness(lowNoise, coverage, kCloudLow), low, key.xyz, coverage, noise, lowDx, lowDy);
                float3 shown    = skyGrade(cloudRadiance(arriving, through, cosine, upward, ambient)) + glow;
                float  shownLow = lowDensity * kCloudLow.opacity * behind.a;
                colour = mix(colour, shown, shownLow);
                clouds = 1.0f - (1.0f - clouds) * (1.0f - shownLow);
            }
        }
    }
    colour = skyOvercast(colour, sky.nightGlowLow.w);
    // The sun and moon are BEHIND the clouds: a thick cloud hides the disc,
    // a thin one only dims it, and the glow around it carries through more.
    float discClear = 1.0f - clouds * 0.95f;
    float glowClear = 1.0f - clouds * 0.6f;

    // ── Sun disc + glow ───────────────────────────────────────────────
    // Only within 39° of it: past that the bloom is under a 255th.
    float cosG = dot(viewDir, sunDir);
    if (sunDir.y > -0.10f && cosG > 0.78f) {
        // The disc over the sky, not added to it, so a red sun still shows
        // against the bright glow around it; its colour less deep than the
        // light it gives, as the eye sees a sun it can't look at.
        float disc  = pow(cosG, sky.sunColorAndSize.w);
        float bloom = pow(cosG, 18.0f) * 0.15f;
        float3 discColour = sqrt(sky.sunColorAndSize.rgb);
        colour = mix(colour, discColour, saturate(disc * 1.5f) * discClear);
        colour += sky.sunColorAndSize.rgb * bloom * glowClear;
    }

    // ── Moon ──────────────────────────────────────────────────────────
    // Only within 37° of it: past that its glow is under a thousandth.
    if (moonVis > 0.01f && cosM > 0.8f) {
        float mGlow = pow(cosM, 32.0f) * 0.12f * sky.bodyParams.z * night * moonVis;
        colour += float3(0.80f, 0.85f, 0.95f) * mGlow * glowClear;
        float mDisc = smoothstep(sky.moonEdges.z, sky.moonEdges.w, cosM);
        if (mDisc > 0.0f) {
            // The disc as a sphere lit from the sun's direction: the phase,
            // and the tilt of its horns, follow from where the two stand.
            float3 lateral = (viewDir - moonDir * cosM) / sin(moonRadius);
            float  r2      = min(dot(lateral, lateral), 1.0f);
            float3 normal  = lateral - moonDir * sqrt(1.0f - r2);
            float  lit     = smoothstep(-0.03f, 0.08f, dot(normal, sunDir));
            // Darker seas, fixed to the face.
            float3 right = normalize(cross(float3(0.0f, 1.0f, 0.0f), moonDir) + float3(1e-4f, 0.0f, 0.0f));
            float2 face  = float2(dot(lateral, right), dot(lateral, cross(moonDir, right)));
            float  seas  = smoothstep(0.45f, 0.75f, skyValueNoise(face * 2.6f + float2(3.1f, 7.7f)));
            // By day the highlands must outshine a sky nearly their colour;
            // the seas, darker, let its blue through, as they do.
            float3 albedo = float3(0.85f, 0.88f, 0.95f) * (1.0f - 0.22f * seas) * mix(1.25f, 1.0f, night);
            float  shown = mDisc * moonVis * discClear;
            colour = mix(colour, albedo, shown * lit);
            // Earthshine: the night side faintly lit by the Earth, strongest
            // under a thin crescent.
            colour += albedo * 0.06f * (1.0f - sky.moonDirectionAndPhase.w) * night * (1.0f - lit) * shown;
        }
    }

    return float4(colour, 1.0f);
}

// MARK: - Catalogue stars

struct SkyStarOut {
    float4 position [[position]];
    float2 corner;      // −1…1 across the sprite
    float3 light;       // tint × brightness, every fade already applied
};

// Each bright star is a small quad facing the camera, its size and
// brightness set by magnitude. Everything that dims a star — daylight, the
// horizon, the moon in front of it or its glare, the clouds, twinkling — is
// worked out here, once a star.
vertex SkyStarOut sky_star_vertex(
    uint                   vid   [[vertex_id]],
    uint                   iid   [[instance_id]],
    constant SkyUniforms  &sky   [[buffer(0)]],
    const device SkyStar  *stars [[buffer(1)]],
    constant float4x4     &viewProjection [[buffer(2)]],
    constant SkyAtmosphereParams &a [[buffer(3)]],
    texture2d<float>       noise [[texture(0)]]
) {
    SkyStarOut out;
    SkyStar star = stars[iid];
    float3 dir = normalize(sky.starRotation * star.directionAndMagnitude.xyz);
    float  magnitude = star.directionAndMagnitude.w;
    float  faintness = saturate((magnitude + 1.5f) / 5.0f);   // Sirius 0 … magnitude 3.5 1

    float3 moonDir = sky.moonDirectionAndPhase.xyz;
    float  cosM    = dot(dir, moonDir);
    float  hidden  = smoothstep(sky.moonEdges.x, sky.moonEdges.y, cosM);
    // Near the horizon: dimmer through more air, and twinkling.
    float  low     = 1.0f - smoothstep(0.03f, 0.35f, dir.y);
    float  phase   = skyCellHash(uint2(iid, 7u), 0u);
    float  twinkle = 1.0f - low * 0.55f * (0.5f + 0.5f * sin(sky.cloudParams.x * (9.0f + 7.0f * phase) + phase * 50.0f));
    float  visible = sky.cloudParams.w
        * smoothstep(-0.01f, 0.04f, dir.y) * (1.0f - 0.55f * low) * twinkle
        * (1.0f - hidden) * (1.0f - 0.3f * moonGlare(cosM, moonDir, sky))
        * (1.0f - cloudCover(dir, sky, noise, a) * 0.95f);
    out.light = star.color.rgb * mix(1.5f, 0.38f, faintness) * visible;

    float2 corner = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? 1.0f : -1.0f);
    out.corner = corner;
    float4 centre = viewProjection * float4(dir, 0.0f);
    if (visible < 0.002f || centre.w <= 0.0f) {
        out.position = float4(0.0f, 0.0f, 0.0f, 1.0f);   // all four corners on one point: nothing drawn
        return out;
    }
    float3 side = normalize(cross(abs(dir.y) < 0.99f ? float3(0.0f, 1.0f, 0.0f) : float3(1.0f, 0.0f, 0.0f), dir));
    float3 up   = cross(dir, side);
    float  size = mix(0.0070f, 0.0028f, faintness);   // radians, corner to centre
    float4 clip = viewProjection * float4(dir + (side * corner.x + up * corner.y) * size, 0.0f);
    out.position = float4(clip.xy, clip.w * 0.9999f, clip.w);
    return out;
}

fragment float4 sky_star_fragment(SkyStarOut in [[stage_in]]) {
    float r2 = dot(in.corner, in.corner);
    float glow = exp(-r2 * 10.0f) + exp(-r2 * 3.0f) * 0.18f;
    return float4(in.light * glow * (1.0f - smoothstep(0.75f, 1.0f, r2)), 0.0f);
}
