#include <metal_stdlib>
#include "MToonCommon.metal"

using namespace metal;

// Vertex shader with optional morphed positions buffer
vertex VertexOut mtoon_vertex(VertexIn in [[stage_in]],
                       constant Uniforms& uniforms [[buffer(1)]],
                       constant MToonMaterial& material [[buffer(8)]],
                       device float3* morphedPositions [[buffer(20)]],
                       constant uint& hasMorphed [[buffer(22)]],
                       uint vertexID [[vertex_id]]) {
    VertexOut out;

    float3 morphedPosition;
    if (hasMorphed > 0) {
        morphedPosition = float3(morphedPositions[vertexID]);
    } else {
        morphedPosition = in.position;
    }

    float3 morphedNormal = normalize(in.normal);
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
                        sampler textureSampler [[sampler(0)]]) {

    // ── UV selection ────────────────────────────────────────────
    float2 uv = in.texCoord;
    if (material.uvOffsetX != 0.0 || material.uvOffsetY != 0.0 || material.uvScale != 1.0) {
        uv = uv * material.uvScale + float2(material.uvOffsetX, material.uvOffsetY);
    }
    if (material.hasUvAnimationMaskTexture > 0) {
        float mask = uvAnimationMaskTexture.sample(textureSampler, in.texCoord).r;
        uv = mix(in.texCoord, in.animatedTexCoord, mask);
    } else if (material.uvAnimationScrollXSpeedFactor != 0.0 ||
               material.uvAnimationScrollYSpeedFactor != 0.0 ||
               material.uvAnimationRotationSpeedFactor != 0.0) {
        uv = in.animatedTexCoord;
    }

    // ── Base + shade colour ─────────────────────────────────────
    float4 baseColor = material.baseColorFactor;
    if (material.hasBaseColorTexture > 0) {
        baseColor *= baseColorTexture.sample(textureSampler, uv);
    }
    if (material.alphaMode == 0) { baseColor.a = 1.0; }
    if (material.alphaMode == 1 && baseColor.a < material.alphaCutoff) { discard_fragment(); }

    float3 shadeColor = float3(material.shadeColorR, material.shadeColorG, material.shadeColorB);
    if (material.hasShadeMultiplyTexture > 0) {
        shadeColor *= shadeMultiplyTexture.sample(textureSampler, uv).rgb;
    }

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
        float3 nmap = normalTexture.sample(textureSampler, uv).xyz * 2.0 - 1.0;
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
        float sv = shadingShiftTexture.sample(textureSampler, uv).r;
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
        float step0   = linearstep(-1.0 + toony, 1.0 - toony, shading0);
        lit0 = mix(shadeColor, baseColor.rgb, step0) * uniforms.lightColor.xyz * (intensity0 / totalIntensity);
        lightingForRim += uniforms.lightColor.xyz * max(ndotl0, 0.0) * (intensity0 / totalIntensity);
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
    // Spec: `color = color + gi × baseColorTerm` — indirect light is added at
    // FULL strength. giEqualizationFactor only blends directional (SH) GI
    // against its uniform average; with a single uniform ambient colour that
    // blend is a no-op, so the factor must NOT scale the ambient. Scaling it
    // (×0.05–0.1) starved the shade side, which read darker/more saturated
    // than reference viewers — most visible on skin.
    float3 litColor = (lit0 + lit1 + lit2) * uniforms.lightNormalizationFactor
                    + uniforms.ambientColor.xyz * baseColor.rgb;

    // ── Emissive ────────────────────────────────────────────────
    float3 emissive = float3(material.emissiveR, material.emissiveG, material.emissiveB);
    if (material.hasEmissiveTexture > 0) {
        emissive *= emissiveTexture.sample(textureSampler, uv).rgb;
    }
    litColor += emissive;

    // ── Rim (spec: matcap + parametric combined, then rimMultiply, then lightingMix) ─
    float3 rim = float3(0.0);

    // MatCap (spec: world-view tangent basis UV)
    if (material.hasMatcapTexture > 0) {
        float2 matcapUV = calculateMatCapUV(normal, in.viewDirection);
        rim += matcapTexture.sample(textureSampler, matcapUV).rgb
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
        rim *= rimMultiplyTexture.sample(textureSampler, uv).rgb;
    }

    // Apply lighting mix (spec: rim × lerp(1, lighting, factor); 0=pure, 1=lit)
    rim *= mix(float3(1.0), lightingForRim, material.rimLightingMixFactor);

    litColor += rim;

    litColor = saturate(max(litColor, baseColor.rgb * 0.08));
    return float4(litColor, baseColor.a);
}
