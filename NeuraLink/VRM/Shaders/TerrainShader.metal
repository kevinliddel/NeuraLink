//
//  TerrainShader.metal
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//
//  64×64 subdivided ground mesh with Gaussian dune features + sinusoidal wind
//  ripples. Maximum displacement ≈ 22 cm (amp=0.22). Centre suppressed 0-1 m
//  for foot placement. Shadows via 5-tap PCF shadow map (sun + moon).

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms (must match TerrainUniforms in Swift, 176 bytes)

struct TerrainUniforms {
    float4x4 viewProjection;        // vertex: world → clip
    float4x4 lightViewProjection;   // shadow: world → light clip
    float4   sunDirection;          // xyz = toward-sun unit vector
    float4   snowColor;             // xyz = base snow colour
    float4   terrainParams;         // x=unused y=amp z=shadowSoft w=time
};

// MARK: - Terrain height

/// Radial Gaussian bump centred at (cx, cz), spread sigma, relative amplitude.
static float gaussDune(float x, float z, float cx, float cz, float sigma, float relAmp) {
    float dx = x - cx, dz = z - cz;
    return relAmp * exp(-(dx * dx + dz * dz) / (2.0f * sigma * sigma));
}

/// Height in world units.
/// kDuneNorm scales radial normalisation independently of the mesh coverage (kHalfSize).
/// Dune centres are in real world-space metres — visible at 5-20 m from the character.
static float computeDuneHeight(float x, float z, float amp) {
    const float kDuneNorm = 20.0f;   // reference radius for radial normalisation
    float radialNorm = min(1.25f, length(float2(x, z)) / kDuneNorm);

    // Flat zone within ~1 m of character; dunes build up to full height by ~3.6 m.
    float centerSuppress = smoothstep(0.05f, 0.18f, radialNorm);
    float farBoost       = 0.90f + 0.45f * smoothstep(0.45f, 0.96f, radialNorm);

    // Six Gaussian mounds at human-visible distances (5–20 m from centre).
    float height = 0.0f;
    height += gaussDune(x, z,  -9.0f,  -2.0f, 4.5f, 0.88f);
    height += gaussDune(x, z,   5.5f,  -7.5f, 4.8f, 0.82f);
    height += gaussDune(x, z,   3.0f,   6.0f, 3.8f, 0.76f);
    height += gaussDune(x, z,  13.0f,   1.5f, 4.5f, 0.90f);
    height += gaussDune(x, z, -16.0f,  10.0f, 5.5f, 0.95f);
    height += gaussDune(x, z,  19.0f, -11.0f, 6.0f, 1.00f);

    // Wind ripples — frequencies tuned to 20 m scale for natural snow texture.
    float rippleGain = 0.25f + 0.75f * smoothstep(0.08f, 1.0f, radialNorm);
    height += (sin(x * 1.70f + z * 0.50f) * 0.30f
             + sin(x * 0.60f - z * 1.40f) * 0.21f
             + sin((x + z)   * 0.90f)     * 0.15f) * rippleGain;

    height *= centerSuppress * farBoost;

    // Sink outer rim for a clean fade toward the horizon.
    float edgeBlend = smoothstep(0.74f, 1.03f, radialNorm);
    height -= edgeBlend * edgeBlend * 0.40f;

    return height * amp;
}

// MARK: - Vertex — generates 64×64 grid inline (no vertex buffer)

constant int   kGridSize = 64;
constant float kHalfSize = 100.0f;  // mesh coverage ±100 m

struct TerrainOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
};

vertex TerrainOut terrain_vertex(
    uint vid [[vertex_id]],
    constant TerrainUniforms &u [[buffer(0)]]
) {
    float amp  = u.terrainParams.y;
    float step = (kHalfSize * 2.0f) / float(kGridSize);

    uint quadIdx  = vid / 6;
    uint localIdx = vid % 6;
    uint qx = quadIdx % uint(kGridSize);
    uint qz = quadIdx / uint(kGridSize);

    // Two CCW triangles per quad (+Y facing when viewed from above):
    // Tri A: (0,0) (0,1) (1,0)  → localIdx 0 1 2
    // Tri B: (1,0) (0,1) (1,1)  → localIdx 3 4 5
    uint dx = (localIdx == 2 || localIdx == 3 || localIdx == 5) ? 1 : 0;
    uint dz = (localIdx == 1 || localIdx == 4 || localIdx == 5) ? 1 : 0;

    float px = -kHalfSize + float(qx + dx) * step;
    float pz = -kHalfSize + float(qz + dz) * step;
    float py = computeDuneHeight(px, pz, amp);

    // Normal via finite differences of the height function.
    float eps = step * 0.4f;
    float hx  = computeDuneHeight(px + eps, pz, amp);
    float hz  = computeDuneHeight(px, pz + eps, amp);
    float3 normal = normalize(float3(-(hx - py) / eps, 1.0f, -(hz - py) / eps));

    TerrainOut out;
    out.worldPos = float3(px, py, pz);
    out.normal   = normal;
    out.position = u.viewProjection * float4(px, py, pz, 1.0f);
    return out;
}

// MARK: - Shadow PCF (5-tap, manual comparison)

static float sampleShadow(
    texture2d<float> shadowMap,
    sampler          smp,
    float3           worldPos,
    float4x4         lightVP,
    float            softness
) {
    float4 lightClip = lightVP * float4(worldPos, 1.0f);
    float3 ndc = lightClip.xyz / lightClip.w;
    if (ndc.x < -1 || ndc.x > 1 || ndc.y < -1 || ndc.y > 1) return 0.0f;
    if (ndc.z <  0 || ndc.z >  1) return 0.0f;

    // Metal textures: (0,0) = top-left; NDC y+ = up → flip y.
    float2 uv   = float2(ndc.x * 0.5f + 0.5f, -ndc.y * 0.5f + 0.5f);
    float  recv = ndc.z - 0.003f;
    float2 ts   = softness / float2(shadowMap.get_width(), shadowMap.get_height());

    float s = 0.0f;
    s += (recv > shadowMap.sample(smp, uv).r)                     ? 1.0f : 0.0f;
    s += (recv > shadowMap.sample(smp, uv + float2(-1, 0) * ts).r) ? 1.0f : 0.0f;
    s += (recv > shadowMap.sample(smp, uv + float2( 1, 0) * ts).r) ? 1.0f : 0.0f;
    s += (recv > shadowMap.sample(smp, uv + float2( 0,-1) * ts).r) ? 1.0f : 0.0f;
    s += (recv > shadowMap.sample(smp, uv + float2( 0, 1) * ts).r) ? 1.0f : 0.0f;
    return s * 0.2f;
}

// MARK: - Fragment

fragment float4 terrain_fragment(
    TerrainOut              in        [[stage_in]],
    constant TerrainUniforms &u       [[buffer(0)]],
    texture2d<float>        shadowMap [[texture(0)]],
    sampler                 shadowSmp [[sampler(0)]]
) {
    float3 normal     = normalize(in.normal);
    float3 sunDir     = u.sunDirection.xyz;
    float  shadowSoft = u.terrainParams.z;

    float NdotL   = max(dot(normal, sunDir), 0.0f);
    float ambient = 0.40f + max(sunDir.y, 0.0f) * 0.30f;
    float shadow  = shadowSoft > 0.0f
                    ? sampleShadow(shadowMap, shadowSmp, in.worldPos, u.lightViewProjection, shadowSoft)
                    : 0.0f;

    float lighting = ambient + NdotL * (1.0f - shadow * 0.75f);

    // Subtle cavity darkening in dune valleys.
    float cavity = (1.0f - normal.y) * 0.16f;

    float3 colour = u.snowColor.xyz * (lighting - cavity);

    // Atmospheric haze toward the horizon.
    float  dist    = length(in.worldPos.xz);
    float  haze    = smoothstep(20.0f, 90.0f, dist);
    float3 hazeCol = mix(float3(0.72f, 0.78f, 0.88f), float3(0.55f, 0.65f, 0.80f),
                         max(sunDir.y, 0.0f));
    colour = mix(colour, hazeCol, haze * 0.60f);

    return float4(colour, 1.0f);
}
