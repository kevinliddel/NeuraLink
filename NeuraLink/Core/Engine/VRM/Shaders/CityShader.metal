//
//  CityShader.metal
//  NeuraLink
//
//  City environment shader — pre-baked textures.
//
//  The city GLB has lighting baked into its textures, so the shader
//  must NOT add significant re-lighting on top.  We output the texture
//  colour almost directly (0.88 base ambient) with a tiny directional
//  term (0.12) so the 3D form is still readable, plus PCF contact
//  shadows and capped emissive for lamp globes.

#include <metal_stdlib>
using namespace metal;

struct CityShadowVertexIn {
    float3 position [[attribute(0)]];
};
struct CityVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
    float4 color    [[attribute(3)]];
};
struct CityShadowUniforms {
    float4x4 lightViewProjection;
};
struct CityUniforms {
    float4x4 viewProjection;
    float4x4 lightViewProjection;
    float4   sunDirection;            // xyz = effective sun dir, w = sun height (signed)
    float4   cityParams;              // x = shadowSoft
    float4   cameraPosition;          // xyz = camera world position
    float4x4 vrmLightViewProjection;  // tight VRM shadow map projection
};
struct CityVertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 texcoord;
    float4 vertexColor;
};

// MARK: - Shadow depth vertex

vertex float4 city_shadow_vertex(
    CityShadowVertexIn         in [[stage_in]],
    constant CityShadowUniforms &u [[buffer(1)]],
    constant float4x4 &modelMatrix [[buffer(2)]]
) {
    return u.lightViewProjection * (modelMatrix * float4(in.position, 1.0));
}

// MARK: - Main vertex

vertex CityVertexOut city_vertex(
    CityVertexIn               in [[stage_in]],
    constant CityUniforms      &u [[buffer(1)]],
    constant float4x4 &modelMatrix [[buffer(2)]]
) {
    float4   wp = modelMatrix * float4(in.position, 1.0);
    float3x3 nm = float3x3(modelMatrix[0].xyz, modelMatrix[1].xyz, modelMatrix[2].xyz);
    CityVertexOut out;
    out.position    = u.viewProjection * wp;
    out.worldPos    = wp.xyz;
    out.normal      = normalize(nm * in.normal);
    out.texcoord    = in.texcoord;
    out.vertexColor = in.color;
    return out;
}

// MARK: - Shadow PCF (9-tap)

static float citySampleShadow(
    texture2d<float> shadowMap, sampler smp,
    float3 worldPos, float4x4 lightVP, float softness
) {
    float4 lc  = lightVP * float4(worldPos, 1.0);
    float3 ndc = lc.xyz / lc.w;
    if (any(abs(ndc.xy) > 1.0f) || ndc.z < 0.0f || ndc.z > 1.0f) return 0.0f;
    float2 uv   = float2(ndc.x * 0.5f + 0.5f, -ndc.y * 0.5f + 0.5f);
    float  recv = ndc.z - 0.002f;
    float2 ts   = softness / float2(shadowMap.get_width(), shadowMap.get_height());
    float s = 0.0f;
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++)
            s += (recv > shadowMap.sample(smp, uv + float2(dx, dy) * ts).r) ? 1.0f : 0.0f;
    return s / 9.0f;
}

// MARK: - Fragment

fragment float4 city_fragment(
    CityVertexOut              in              [[stage_in]],
    constant CityUniforms     &u               [[buffer(1)]],
    constant float4           &baseColorFactor [[buffer(2)]],
    // xyz = emissiveFactor (capped in shader), w = alphaCutoff
    constant float4           &emissivePacked  [[buffer(3)]],
    // x = metallic, y = roughness, z = hasNormalMap, w = normalScale
    constant float4           &materialParams  [[buffer(4)]],
    texture2d<float>           albedo          [[texture(0)]],
    texture2d<float>           shadowMap       [[texture(1)]],  // wide city shadow
    texture2d<float>           vrmShadowMap    [[texture(2)]],  // tight VRM shadow
    texture2d<float>           normalMap       [[texture(3)]],  // tangent-space normal map
    sampler                    shadowSmp       [[sampler(0)]]
) {
    constexpr sampler smp(filter::linear, mip_filter::linear,
                          address::repeat, max_anisotropy(16));

    // Base colour: texture × material factor × vertex colour
    float4 color = albedo.sample(smp, in.texcoord) * baseColorFactor * in.vertexColor;
    if (color.a < emissivePacked.w) discard_fragment();

    float3 N         = normalize(in.normal);

    // Normal map — screen-space derivative TBN (no pre-computed tangents needed)
    if (materialParams.z > 0.5f) {
        float3 q1  = dfdx(in.worldPos);
        float3 q2  = dfdy(in.worldPos);
        float2 st1 = dfdx(in.texcoord);
        float2 st2 = dfdy(in.texcoord);
        float3 T   = normalize(q1 * st2.y - q2 * st1.y);
        float3 B   = normalize(-q1 * st2.x + q2 * st1.x);
        float3x3 TBN = float3x3(T, B, N);
        float3 nmap  = normalMap.sample(smp, in.texcoord).xyz * 2.0f - 1.0f;
        nmap.xy     *= materialParams.w;  // normalScale
        N = normalize(TBN * nmap);
    }
    float3 sunDir    = u.sunDirection.xyz;
    float  sunH      = u.sunDirection.w;
    float  sunStr    = saturate(sunH + 0.30f);
    float  metallic  = materialParams.x;
    float  roughness = max(materialParams.y, 0.04f);

    float NdotL = max(dot(N, sunDir), 0.0f);
    float cityShadow = (u.cityParams.x > 0.0f)
        ? citySampleShadow(shadowMap,    shadowSmp, in.worldPos,
                           u.lightViewProjection,    u.cityParams.x)
        : 0.0f;
    // VRM tight shadow map: character casts a shadow on the city ground.
    // Fragments outside the tight frustum return 0 automatically (no shadow).
    float vrmShadow = citySampleShadow(vrmShadowMap, shadowSmp, in.worldPos,
                                       u.vrmLightViewProjection, 1.5f);
    float shadow = max(cityShadow, vrmShadow);

    // Time-of-day hemisphere ambient.
    // Three keyframes: night (dark blue), sunrise/set (warm orange), midday (cool blue).
    float  dayFactor    = saturate(sunH * 2.5f + 0.25f);          // 0=night, 1=day
    float  sunsetFactor = saturate(1.0f - abs(sunH) * 5.5f) * 0.70f; // peaks at horizon

    float3 daySky    = float3(1.00f, 1.05f, 1.15f);  // midday blue-white
    float3 sunsetSky = float3(1.20f, 0.80f, 0.55f);  // warm orange at horizon
    float3 nightSky  = float3(0.22f, 0.25f, 0.42f);  // moonlit sky — cool blue-purple
    float3 skyAmb    = mix(nightSky, daySky, dayFactor);
           skyAmb    = mix(skyAmb, sunsetSky, sunsetFactor);

    float3 dayGnd    = float3(0.65f, 0.62f, 0.56f);  // warm gray ground bounce
    float3 nightGnd  = float3(0.18f, 0.13f, 0.20f);  // city night — warm-purple from street lamps
    float3 gndAmb    = mix(nightGnd, dayGnd, dayFactor);

    float  hemi    = N.y * 0.5f + 0.5f;
    float3 ambient = mix(gndAmb, skyAmb, hemi);

    // Artificial city light (street lamps, shop windows) — additive warm glow at night,
    // strongest on downward-facing surfaces (asphalt, awnings), fades at sunrise.
    float3 cityArtificial = float3(0.10f, 0.06f, 0.02f) * (1.0f - dayFactor) * (1.0f - hemi);
    ambient += cityArtificial;

    float  dirStr    = 0.20f * NdotL * sunStr;
    float  shadowF   = 1.0f - shadow * sunStr * 0.30f; // stronger contrast in daylight
    float  diffScale = 1.0f - metallic * 0.8f;
    float3 lit = color.rgb * (ambient + dirStr) * shadowF * diffScale;

    // View direction — used for specular and glass.
    float3 viewDir = normalize(u.cameraPosition.xyz - in.worldPos);

    // Unified Blinn-Phong specular — metallic AND dielectric surfaces.
    // Metallic  → strong albedo-tinted highlight, scales with (1-roughness).
    // Dielectric → subtle neutral highlight, F0≈0.04, scales with (1-roughness)².
    // e.g. CityGenbasic_metal.001 (M:0, R:0.26) and CityGenroof (M:0, R:0.50)
    //      both pick up a small sheen; fully rough surfaces (R:1.0) get nothing.
    if (sunStr > 0.0f) {
        float3 halfVec   = normalize(sunDir + viewDir);
        float  NdotH     = max(dot(N, halfVec), 0.0f);
        float  shininess = 2.0f / (roughness * roughness + 0.001f);
        float  specPow   = pow(NdotH, clamp(shininess, 2.0f, 2048.0f));
        float  litMask   = sunStr * (1.0f - shadow);

        float  metStr  = metallic * (1.0f - roughness) * 0.40f * litMask;
        float3 metSpec = mix(float3(0.04f), color.rgb, metallic) * specPow * metStr;

        float  dielStr = (1.0f - metallic) * pow(1.0f - roughness, 2.0f) * 0.10f * litMask;
        float3 dielSpec = float3(specPow * dielStr);

        lit += metSpec + dielSpec;
    }

    // Glass: very smooth + semi-transparent → add Fresnel sky-reflection tint.
    // Matches CityGenGlass.001 (R=0, alpha=0.25, no texture).
    if (roughness < 0.05f && color.a < 0.9f) {
        float  cosTheta = saturate(dot(N, viewDir));
        float  fresnel  = pow(1.0f - cosTheta, 5.0f);
        float3 reflTint = float3(0.78f, 0.88f, 1.00f);  // sky reflection tint
        lit     = mix(lit, reflTint, 0.25f + fresnel * 0.55f);
        color.a = saturate(color.a + fresnel * 0.50f);
    }

    // Emissive
    lit += min(emissivePacked.xyz, float3(0.35f));

    // Distance haze — city scale (80–160 m), tinted by time of day
    float  dist     = length(in.worldPos.xz);
    float  haze     = smoothstep(80.0f, 160.0f, dist);
    float3 dayHaze  = float3(0.70f, 0.76f, 0.88f);  // blue-gray midday
    float3 sunHaze  = float3(0.88f, 0.70f, 0.58f);  // orange sunset haze
    float3 nightHaze = float3(0.05f, 0.06f, 0.12f); // near-black night
    float3 hazeCol  = mix(nightHaze, dayHaze, dayFactor);
           hazeCol  = mix(hazeCol, sunHaze, sunsetFactor);
    lit = mix(lit, hazeCol, haze * 0.45f);

    return float4(lit, color.a);
}
