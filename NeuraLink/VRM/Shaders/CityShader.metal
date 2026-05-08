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
    // x = metallicFactor, y = roughnessFactor
    constant float4           &materialParams  [[buffer(4)]],
    texture2d<float>           albedo          [[texture(0)]],
    texture2d<float>           shadowMap       [[texture(1)]],  // wide city shadow
    texture2d<float>           vrmShadowMap    [[texture(2)]],  // tight VRM shadow
    sampler                    shadowSmp       [[sampler(0)]]
) {
    constexpr sampler smp(filter::linear, mip_filter::linear,
                          address::repeat, max_anisotropy(16));

    // Base colour: texture × material factor × vertex colour
    float4 color = albedo.sample(smp, in.texcoord) * baseColorFactor * in.vertexColor;
    if (color.a < emissivePacked.w) discard_fragment();

    float3 N         = normalize(in.normal);
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

    // Hemisphere ambient: approximates outdoor IBL.
    // Sky-facing normals (N.y→+1) receive cool blue sky light;
    // ground-facing (N.y→-1) receive warm gray bounce light.
    // Calibrated so the weighted average for a city scene ≈ 0.88 neutral.
    float3 skyAmb  = float3(1.00f, 1.05f, 1.15f);   // cool blue-white sky
    float3 gndAmb  = float3(0.65f, 0.62f, 0.56f);   // warm gray ground bounce
    float  hemi    = N.y * 0.5f + 0.5f;              // 0 = full ground, 1 = full sky
    float3 ambient = mix(gndAmb, skyAmb, hemi);

    float  dirStr    = 0.18f * NdotL * sunStr;
    float  shadowF   = 1.0f - shadow * sunStr * 0.22f; // shadows dim ambient slightly
    float  diffScale = 1.0f - metallic * 0.8f;
    float3 lit = color.rgb * (ambient + dirStr) * shadowF * diffScale;

    // View direction — used for specular and glass.
    float3 viewDir = normalize(u.cameraPosition.xyz - in.worldPos);

    // Blinn-Phong specular for metallic materials.
    if (metallic > 0.05f && sunStr > 0.0f) {
        float3 halfVec  = normalize(sunDir + viewDir);
        float  NdotH    = max(dot(N, halfVec), 0.0f);
        float  shininess = 2.0f / (roughness * roughness + 0.001f);
        float  specPow  = pow(NdotH, clamp(shininess, 2.0f, 2048.0f));
        float3 specTint = mix(float3(0.04f), color.rgb, metallic);
        float  specStr  = metallic * (1.0f - roughness) * 0.4f * sunStr * (1.0f - shadow);
        lit += specTint * specPow * specStr;
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

    // Distance haze (50–90 m)
    float  dist    = length(in.worldPos.xz);
    float  haze    = smoothstep(50.0f, 90.0f, dist);
    float3 hazeCol = mix(float3(0.68f, 0.74f, 0.86f),
                         float3(0.52f, 0.62f, 0.78f), max(sunH, 0.0f));
    lit = mix(lit, hazeCol, haze * 0.50f);

    return float4(lit, color.a);
}
