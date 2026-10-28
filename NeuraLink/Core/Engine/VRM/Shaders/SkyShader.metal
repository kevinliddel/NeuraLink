//
//  SkyShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//
//  The sky: the atmosphere looked up from its sky-view table
//  (SkyAtmosphere.metal), the night's own glow under it, then the sun disc,
//  dome clouds, a moon lit from the sun's side, and stars that turn with the
//  sky — a procedural faint field here, the catalogue's bright ones as
//  sprites (sky_star_vertex / sky_star_fragment).

#include "SkyAtmosphereCommon.metal"

// MARK: - Uniforms (must match SkyUniformsData in Swift, 224 bytes)

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
};

// One catalogue star (must match SkyStarData in Swift, 32 bytes).
struct SkyStar {
    float4 directionAndMagnitude;       // xyz = J2000 equatorial unit vector, w = V magnitude
    float4 color;                       // rgb = tint from B−V
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
    float2 seed  = cell + float(face) * 97.0f;
    float2 centre = (cell + 0.5f) / cells * 2.0f - 1.0f;
    float chance = 0.07f * pow(1.0f + dot(centre, centre), -1.5f);
    float rnd    = skyHash(seed);
    if (rnd > chance) return 0.0f;
    float2 jitter = float2(skyHash(seed + 13.7f), skyHash(seed + 71.3f)) * 0.5f + 0.25f;
    float3 star   = cubeFaceDirection(face, (cell + jitter) / cells * 2.0f - 1.0f);
    float angle   = length(cross(d, star));       // sin θ ≈ θ this close
    float bright  = rnd / chance;                 // 0…1 among the cells that hold one
    float radius  = 0.0015f + 0.0013f * bright;   // radians
    return smoothstep(radius, radius * 0.3f, angle) * (0.22f + 0.5f * bright * bright);
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

// Both cloud layers over `viewDir`, combined [0, 1].
static float skyClouds(float3 viewDir, constant SkyUniforms &sky) {
    float coverage = sky.cloudParams.z;
    if (coverage <= 0.001f) return 0.0f;
    float cloudsLow  = cloudLayer(viewDir, sky.cloudParams.x, sky.cloudParams.y, 2.0f, coverage);
    float cloudsHigh = cloudLayerHigh(viewDir, sky.cloudParams.x, sky.cloudParams.y, 2.0f, coverage * 0.90f);
    return clamp(cloudsLow + cloudsHigh * (1.0f - cloudsLow), 0.0f, 1.0f);
}

// Moonlight washing the stars out [0, 1]: the moon's brightness while it is
// up, and more of it near the moon.
static float moonGlare(float cosM, float3 moonDir, constant SkyUniforms &sky) {
    float up = smoothstep(-0.02f, 0.06f, moonDir.y);
    return sky.bodyParams.z * up * (0.45f + 0.55f * smoothstep(0.8f, 0.995f, cosM));
}

// MARK: - The atmosphere's colour

// A sky-view radiance as shown: a soft shoulder so the bright sky near the
// sun rolls off instead of clipping, and a little more saturation, toward
// the toon-shaded avatar in front of it.
static float3 skyGrade(float3 radiance) {
    float3 shown = 1.0f - exp(-radiance);
    float  luma  = dot(shown, float3(0.2126f, 0.7152f, 0.0722f));
    return max(mix(float3(luma), shown, 1.25f), 0.0f);
}

// Rain's overcast: the colour drained, the sky darker, as bright as before
// otherwise, so a rainy night stays night.
static float3 skyOvercast(float3 colour, float rain) {
    float luma = dot(colour, float3(0.2126f, 0.7152f, 0.0722f));
    return mix(colour, luma * float3(0.95f, 1.0f, 1.06f), rain * 0.7f) * (1.0f - rain * 0.28f);
}

// The atmosphere along `d` as shown, the night's glow included.
static float3 skyAtmosphere(float3 d, texture2d<float> skyView, constant SkyUniforms &sky) {
    constexpr sampler around(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    float3 colour = skyGrade(skyView.sample(around, skyViewUV(d)).rgb);
    // The night's own glow (airglow, starlight), under twilight: deep blue,
    // a little brighter overhead, darker below the horizon.
    float3 glow = mix(sky.nightGlowLow.rgb, sky.nightGlowHigh.rgb, saturate(d.y * 0.5f + 0.5f));
    colour += glow * mix(1.0f, 0.22f, smoothstep(0.0f, -0.18f, d.y));
    return skyOvercast(colour, sky.nightGlowLow.w);
}

// MARK: - Fragment

fragment float4 sky_fragment(
    SkyOut               in      [[stage_in]],
    constant SkyUniforms &sky    [[buffer(0)]],
    texture2d<float>     skyView [[texture(0)]]
) {
    // Reconstruct world-space view direction from screen UV
    float2 ndc    = in.uv * 2.0f - 1.0f;
    float4 nearPt = sky.invViewProjection * float4(ndc, 0.0f, 1.0f);
    float4 farPt  = sky.invViewProjection * float4(ndc, 1.0f, 1.0f);
    nearPt /= nearPt.w;
    farPt  /= farPt.w;
    float3 viewDir = normalize(farPt.xyz - nearPt.xyz);

    float3 sunDir  = sky.sunDirectionAndIntensity.xyz;
    float3 moonDir = sky.moonDirectionAndPhase.xyz;
    float  moonRadius = sky.bodyParams.x;
    float  starVis = sky.cloudParams.w;

    // The moon is drawn whenever it is up, by day too, part-transparent
    // against a bright sky; its glow only at night.
    float night   = smoothstep(0.05f, -0.10f, sunDir.y);
    float moonVis = smoothstep(-0.02f, 0.03f, moonDir.y) * mix(0.7f, 1.0f, night);
    float  cosM    = dot(viewDir, moonDir);
    // moonOcclude is NOT scaled by moonVis: the moon body is always opaque regardless
    // of how bright it appears — otherwise partial-night stars bleed through the disc.
    // The suppression zone starts wider than the disc edge so the anti-aliased rim is
    // also clean.
    float  moonOcclude = smoothstep(cos(moonRadius * 1.48f), cos(moonRadius), cosM);

    // ── The atmosphere ────────────────────────────────────────────────
    float3 colour = skyAtmosphere(viewDir, skyView, sky);

    // ── Faint stars — turning with the sky, hidden behind the moon ────
    if (starVis > 0.001f && viewDir.y > 0.0f) {
        float star = faintStars(transpose(sky.starRotation) * viewDir);
        float glare = moonGlare(cosM, moonDir, sky);
        colour += float3(star * starVis * (1.0f - 0.7f * glare) * (1.0f - moonOcclude));
    }

    // ── Clouds ────────────────────────────────────────────────────────
    float clouds = skyClouds(viewDir, sky);
    if (clouds > 0.0f) {
        // Tinted by the sky low in their direction: orange on the sunset
        // side, pink opposite, white by day, grey-blue at night.
        float3 horizon   = skyAtmosphere(normalize(float3(viewDir.x, 0.05f, viewDir.z)), skyView, sky);
        float3 cloudTint = clamp(horizon * 1.8f + 0.12f, 0.0f, 1.0f);
        colour = mix(colour, cloudTint, clouds * 0.88f);
    }
    // The sun and moon are BEHIND the clouds: a thick cloud hides the disc,
    // a thin one only dims it, and the glow around it carries through more.
    float discClear = 1.0f - clouds * 0.95f;
    float glowClear = 1.0f - clouds * 0.6f;

    // ── Sun disc + glow ───────────────────────────────────────────────
    if (sunDir.y > -0.10f) {
        // The disc over the sky, not added to it, so a red sun still shows
        // against the bright glow around it; its colour less deep than the
        // light it gives, as the eye sees a sun it can't look at.
        float cosG  = max(dot(viewDir, sunDir), 0.0f);
        float disc  = pow(cosG, sky.sunColorAndSize.w);
        float bloom = pow(cosG, 18.0f) * 0.15f;
        float3 discColour = sqrt(sky.sunColorAndSize.rgb);
        colour = mix(colour, discColour, saturate(disc * 1.5f) * discClear);
        colour += sky.sunColorAndSize.rgb * bloom * glowClear;
    }

    // ── Moon ──────────────────────────────────────────────────────────
    if (moonVis > 0.01f) {
        float mGlow = pow(max(cosM, 0.0f), 32.0f) * 0.12f * sky.bodyParams.z * night * moonVis;
        colour += float3(0.80f, 0.85f, 0.95f) * mGlow * glowClear;
        float mDisc = smoothstep(cos(moonRadius * 1.03f), cos(moonRadius * 0.97f), cosM);
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
    constant float4x4     &viewProjection [[buffer(2)]]
) {
    SkyStarOut out;
    SkyStar star = stars[iid];
    float3 dir = normalize(sky.starRotation * star.directionAndMagnitude.xyz);
    float  magnitude = star.directionAndMagnitude.w;
    float  faintness = saturate((magnitude + 1.5f) / 5.0f);   // Sirius 0 … magnitude 3.5 1

    float3 moonDir = sky.moonDirectionAndPhase.xyz;
    float  cosM    = dot(dir, moonDir);
    float  moonRadius = sky.bodyParams.x;
    float  hidden  = smoothstep(cos(moonRadius * 1.48f), cos(moonRadius), cosM);
    // Near the horizon: dimmer through more air, and twinkling.
    float  low     = 1.0f - smoothstep(0.03f, 0.35f, dir.y);
    float  phase   = skyHash(float2(float(iid), 7.0f));
    float  twinkle = 1.0f - low * 0.55f * (0.5f + 0.5f * sin(sky.cloudParams.x * (9.0f + 7.0f * phase) + phase * 50.0f));
    float  visible = sky.cloudParams.w
        * smoothstep(-0.01f, 0.04f, dir.y) * (1.0f - 0.55f * low) * twinkle
        * (1.0f - hidden) * (1.0f - 0.3f * moonGlare(cosM, moonDir, sky))
        * (1.0f - skyClouds(dir, sky) * 0.95f);
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
