#include <metal_stdlib>
#include "MToonCommon.metal"

using namespace metal;

// Vertex shader with optional morphed positions buffer
vertex VertexOut mtoon_vertex(VertexIn in [[stage_in]],
                       constant Uniforms& uniforms [[buffer(1)]],
                       constant MToonMaterial& material [[buffer(8)]],
                       device float3* morphedPositions [[buffer(20)]],
                       constant uint& hasMorphed [[buffer(22)]],
                       device float3* morphedNormals [[buffer(23)]],
                       uint vertexID [[vertex_id]]) {
    VertexOut out;

    // Morphed positions (bit 1) and normals (bit 2) when expressions are on.
    float3 morphedPosition = (hasMorphed & 1u) != 0 ? float3(morphedPositions[vertexID]) : in.position;
    float3 morphedNormal = normalize((hasMorphed & 2u) != 0 ? float3(morphedNormals[vertexID]) : in.normal);
    float4 worldPosition = uniforms.modelMatrix * float4(morphedPosition, 1.0);
    out.worldPosition = worldPosition.xyz;
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPosition;
    out.worldNormal = normalize((uniforms.normalMatrix * float4(morphedNormal, 0.0)).xyz);
    out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(morphedNormal, 0.0)).xyz);
    out.texCoord = in.texCoord;
    out.animatedTexCoord = animateUV(in.texCoord, material);
    out.color = in.color;

    float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                    uniforms.viewMatrix[1].xyz,
                                    uniforms.viewMatrix[2].xyz);
    float3 cameraPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
    out.viewDirection = normalize(cameraPos - out.worldPosition);

    return out;
}

// Fragment shader — VRMC_materials_mtoon-1.0 spec compliant shading
fragment float4 mtoon_fragment_v2(VertexOut in [[stage_in]],
                        bool isFrontFace [[front_facing]],
                        constant MToonMaterial& material [[buffer(8)]],
                        constant Uniforms& uniforms [[buffer(1)]],
                        texture2d<float> baseColorTexture [[texture(0)]],
                        texture2d<float> shadeMultiplyTexture [[texture(1)]],
                        texture2d<float> shadingShiftTexture [[texture(2)]],
                        texture2d<float> normalTexture [[texture(3)]],
                        texture2d<float> emissiveTexture [[texture(4)]],
                        texture2d<float> matcapTexture [[texture(5)]],
                        texture2d<float> rimMultiplyTexture [[texture(6)]],
                        texture2d<float> uvAnimationMaskTexture [[texture(7)]],
                        depth2d<float> avatarShadowMap [[texture(8)]],
                        constant AvatarShadowParams& avatarShadowParams [[buffer(9)]],
                        sampler textureSampler [[sampler(0)]],
                        sampler avatarShadowSampler [[sampler(1)]],
                        // Each texture's own glTF sampler (wrap, filter).
                        sampler shadeMultiplySampler [[sampler(2)]],
                        sampler shadingShiftSampler [[sampler(3)]],
                        sampler normalSampler [[sampler(4)]],
                        sampler emissiveSampler [[sampler(5)]],
                        sampler matcapSampler [[sampler(6)]],
                        sampler rimMultiplySampler [[sampler(7)]],
                        sampler uvAnimationMaskSampler [[sampler(8)]]) {

    // ── UV: MToon's animation first, then the material's texture
    //    transform (spec order). The animation runs per fragment; the
    //    mask scales both the rotation about (0.5, 0.5) and the scroll.
    float2 uv = in.texCoord;
    if (material.uvAnimationScrollXSpeedFactor != 0.0 ||
        material.uvAnimationScrollYSpeedFactor != 0.0 ||
        material.uvAnimationRotationSpeedFactor != 0.0) {
        float mask = 1.0;
        if (material.hasUvAnimationMaskTexture > 0) {
            // 1.0 reads the B channel (spec, three-vrm); 0.x MToon read R.
            float4 maskSample = uvAnimationMaskTexture.sample(uvAnimationMaskSampler, mtoonTransformUV(uv, material));
            mask = material.vrmVersion == 0 ? maskSample.r : maskSample.b;
        }
        float angle = material.uvAnimationRotationSpeedFactor * material.time * mask;
        float2 centered = uv - 0.5;
        uv = float2(cos(angle) * centered.x - sin(angle) * centered.y,
                    sin(angle) * centered.x + cos(angle) * centered.y) + 0.5;
        uv += float2(material.uvAnimationScrollXSpeedFactor, material.uvAnimationScrollYSpeedFactor)
              * material.time * mask;
    }
    uv = mtoonTransformUV(uv, material);

    // ── Base + shade colour ─────────────────────────────────────
    float4 baseColor = material.baseColorFactor;
    if (material.hasBaseColorTexture > 0) {
        baseColor *= baseColorTexture.sample(textureSampler, uv);
    }
    if (material.alphaMode == 0) { baseColor.a = 1.0; }
    if (material.alphaMode == 1 && baseColor.a < material.alphaCutoff) { discard_fragment(); }
    if (material.alphaMode == 3) {
        // Cutout through alpha-to-coverage: alpha sharpened around the cutoff
        // over one pixel's worth of change, so the edge covers 0…4 samples.
        float edge = max(fwidth(baseColor.a), 1e-4);
        baseColor.a = saturate((baseColor.a - material.alphaCutoff) / edge + 0.5);
        if (baseColor.a <= 0.0) { discard_fragment(); }
    }
    // Character customization: recolour after the sample so alpha cutout
    // and every lighting term below see the adjusted colour.
    baseColor.rgb = nl_applyRecolor(baseColor.rgb, material);

    float3 shadeColor = float3(material.shadeColorR, material.shadeColorG, material.shadeColorB);
    if (material.hasShadeMultiplyTexture > 0) {
        shadeColor *= shadeMultiplyTexture.sample(shadeMultiplySampler, uv).rgb;
    }
    shadeColor = nl_applyRecolor(shadeColor, material);

    // ── Normals ─────────────────────────────────────────────────
    float3 normal = normalize(in.worldNormal);
    float3 viewNormal = in.viewNormal;
    if (!isFrontFace) {
        normal = -normal;
        viewNormal = -viewNormal;
    }
    if (material.hasNormalTexture > 0) {
        // Tangent-space normal mapping without vertex tangents: build the
        // cotangent frame from screen-space derivatives (Schüler,
        // thetenthplanet.de/archives/1180). The previous code added the raw
        // tangent-space sample into the WORLD normal, which dragged every
        // normal toward world +Z even for a neutral (flat) map — most
        // visible as smeared/shifted shading on outfits with fabric maps.
        float3 nmap = normalTexture.sample(normalSampler, uv).xyz * 2.0 - 1.0;
        // glTF normal maps are OpenGL-convention (+Y = image up), but the
        // derivative bitangent below points along +v (image down), so Y
        // must be negated — same as three.js GLTFLoader's
        // `normalScale.y *= -1` when using derivative tangents.
        nmap.xy *= float2(material.normalScale, -material.normalScale);
        float3 dp1 = dfdx(in.worldPosition);
        float3 dp2 = dfdy(in.worldPosition);
        float2 duv1 = dfdx(uv);
        float2 duv2 = dfdy(uv);
        float3 dp2perp = cross(dp2, normal);
        float3 dp1perp = cross(normal, dp1);
        float3 tangent = dp2perp * duv1.x + dp1perp * duv2.x;
        float3 bitangent = dp2perp * duv1.y + dp1perp * duv2.y;
        float invmax = rsqrt(max(dot(tangent, tangent), dot(bitangent, bitangent)));
        // Degenerate UV derivatives (e.g. flat-mapped islands) leave the
        // geometric normal untouched instead of producing NaNs.
        if (isfinite(invmax)) {
            float3x3 tbn = float3x3(tangent * invmax, bitangent * invmax, normal);
            normal = normalize(tbn * nmap);
        }
    }

    // ── Shading shift (spec: texture remapped to [-1,1] × scale) ─
    float shadingShift = material.shadingShiftFactor;
    if (material.hasShadingShiftTexture > 0) {
        float sv = shadingShiftTexture.sample(shadingShiftSampler, uv).r;
        shadingShift += (sv * 2.0 - 1.0) * material.shadingShiftTextureScale;
    }

    // ── Directional lights (spec: raw dot(N,L), not half-Lambert) ─
    float toony = material.shadingToonyFactor;
    float intensity0 = uniforms.lightColor.w;
    float intensity1 = uniforms.light1Color.w;
    float intensity2 = uniforms.light2Color.w;
    float totalIntensity = max(intensity0 + intensity1 + intensity2, 0.001f);

    float3 lit0 = float3(0.0);
    float3 lightingForRim = float3(0.0);
    if (intensity0 > 0.0) {
        float ndotl0  = dot(normal, -uniforms.lightDirection.xyz);
        float shading0 = ndotl0 + shadingShift;
        // Received shadow (three-vrm: shading *= shadow): the key light only,
        // the light the self-shadow map is built from.
        float3 geometricNormal = normalize(in.worldNormal) * (isFrontFace ? 1.0 : -1.0);
        float shadow0 = avatarShadow(avatarShadowMap, avatarShadowSampler, avatarShadowParams,
                                     in.worldPosition, geometricNormal);
        float step0   = linearstep(-1.0 + toony, 1.0 - toony, shading0) * shadow0;
        lit0 = mix(shadeColor, baseColor.rgb, step0) * uniforms.lightColor.xyz * (intensity0 / totalIntensity);
        lightingForRim += uniforms.lightColor.xyz * max(ndotl0, 0.0) * shadow0 * (intensity0 / totalIntensity);
    }
 
    float3 lit1 = float3(0.0);
    if (intensity1 > 0.0) {
        float ndotl1  = dot(normal, -uniforms.light1Direction.xyz);
        float shading1 = ndotl1 + shadingShift;
        float step1   = linearstep(-1.0 + toony, 1.0 - toony, shading1);
        lit1 = mix(shadeColor, baseColor.rgb, step1) * uniforms.light1Color.xyz * (intensity1 / totalIntensity);
        lightingForRim += uniforms.light1Color.xyz * max(ndotl1, 0.0) * (intensity1 / totalIntensity);
    }
 
    float3 lit2 = float3(0.0);
    if (intensity2 > 0.0) {
        float ndotl2  = dot(normal, -uniforms.light2Direction.xyz);
        float shading2 = ndotl2 + shadingShift;
        float step2   = linearstep(-1.0 + toony, 1.0 - toony, shading2);
        lit2 = mix(shadeColor, baseColor.rgb, step2) * uniforms.light2Color.xyz * (intensity2 / totalIntensity);
        lightingForRim += uniforms.light2Color.xyz * max(ndotl2, 0.0) * (intensity2 / totalIntensity);
    }

    lightingForRim *= uniforms.lightNormalizationFactor;

    // ── GI / ambient ────────────────────────────────────────────
    // Spec: `color += gi × baseColorTerm`, gi = lerp(SH(normal), SH average,
    // giEqualizationFactor), added at FULL strength (scaling it by the factor
    // starved the shade side). The SH probe is the sky's light at L1
    // (SkyAmbient): blue from above at noon, orange from the sun's side at
    // dusk. Its average, (SH(up) + SH(down)) / 2, is its mean.
    // giIntensityFactor holds 1 − giEqualizationFactor.
    float3 gi = mix(mtoonAmbientAlong(uniforms, normal), uniforms.ambientColor.xyz,
                    saturate(1.0 - material.giIntensityFactor));
    float3 litColor = (lit0 + lit1 + lit2) * uniforms.lightNormalizationFactor
                    + gi * baseColor.rgb;

    // ── Emissive ────────────────────────────────────────────────
    float3 emissive = float3(material.emissiveR, material.emissiveG, material.emissiveB);
    if (material.hasEmissiveTexture > 0) {
        emissive *= emissiveTexture.sample(emissiveSampler, uv).rgb;
    }
    litColor += emissive;

    // ── Rim (spec: matcap + parametric combined, then rimMultiply, then lightingMix) ─
    float3 rim = float3(0.0);

    // MatCap (spec: world-view tangent basis UV)
    if (material.hasMatcapTexture > 0) {
        float2 matcapUV = calculateMatCapUV(normal, in.viewDirection);
        rim += matcapTexture.sample(matcapSampler, matcapUV).rgb
             * float3(material.matcapR, material.matcapG, material.matcapB);
    }

    // Parametric rim (spec: pow(saturate(1 - dot(N,V) + lift), power))
    float3 rimColorFactor = float3(material.parametricRimColorR,
                                   material.parametricRimColorG,
                                   material.parametricRimColorB);
    if (any(rimColorFactor > 0.0)) {
        float NdotV = saturate(dot(normal, normalize(in.viewDirection)));
        float rimF  = pow(saturate(1.0 - NdotV + material.parametricRimLiftFactor),
                          max(material.parametricRimFresnelPowerFactor, 0.001f));
        rim += rimF * rimColorFactor;
    }

    // Apply rim multiply texture (spec: combined rim × texture)
    if (material.hasRimMultiplyTexture > 0) {
        rim *= rimMultiplyTexture.sample(rimMultiplySampler, uv).rgb;
    }

    // Apply lighting mix (spec: rim × lerp(1, lighting, factor); 0=pure, 1=lit)
    rim *= mix(float3(1.0), lightingForRim, material.rimLightingMixFactor);

    litColor += rim;

    litColor = saturate(max(litColor, baseColor.rgb * 0.08));
    return float4(litColor, baseColor.a);
}
