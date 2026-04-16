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

// Fragment shader with complete MToon 1.0 shading
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

    // Choose UV coordinates
    float2 uv = in.texCoord;
    if (material.uvOffsetX != 0.0 || material.uvOffsetY != 0.0 || material.uvScale != 1.0) {
        uv = uv * material.uvScale + float2(material.uvOffsetX, material.uvOffsetY);
    }
    
    if (material.hasUvAnimationMaskTexture > 0) {
        float animationMask = uvAnimationMaskTexture.sample(textureSampler, in.texCoord).r;
        uv = mix(in.texCoord, in.animatedTexCoord, animationMask);
    } else if (material.uvAnimationScrollXSpeedFactor != 0.0 ||
               material.uvAnimationScrollYSpeedFactor != 0.0 ||
               material.uvAnimationRotationSpeedFactor != 0.0) {
        uv = in.animatedTexCoord;
    }

    // Sample base color
    float4 baseColor = material.baseColorFactor;
    if (material.hasBaseColorTexture > 0) {
        baseColor *= baseColorTexture.sample(textureSampler, uv);
    }

    if (material.alphaMode == 0) {
        baseColor.a = 1.0;
    }

    if (material.alphaMode == 1 && baseColor.a < material.alphaCutoff) {
        discard_fragment();
    }

    // Calculate shade color
    float3 shadeColor = float3(material.shadeColorR, material.shadeColorG, material.shadeColorB);
    if (material.hasShadeMultiplyTexture > 0) {
        shadeColor *= shadeMultiplyTexture.sample(textureSampler, uv).rgb;
    }

    float3 normal = normalize(in.worldNormal);
    float3 viewNormal = in.viewNormal;

    if (!isFrontFace) {
        normal = -normal;
        viewNormal = -viewNormal;
    }

    if (material.hasNormalTexture > 0) {
        float3 normalMapSample = normalTexture.sample(textureSampler, uv).xyz * 2.0 - 1.0;
        normal = normalize(normal + normalMapSample * 0.8);
    }

    // Shading shift calculation
    float shadingShift = material.shadingShiftFactor;
    if (material.hasShadingShiftTexture > 0) {
        float shiftTexValue = shadingShiftTexture.sample(textureSampler, uv).r;
        shadingShift += (shiftTexValue - 0.5) * material.shadingShiftTextureScale;
    }

    float toony = material.shadingToonyFactor;
    float intensity0 = uniforms.lightColor.w;
    float intensity1 = uniforms.light1Color.w;
    float intensity2 = uniforms.light2Color.w;
    float totalIntensity = max(intensity0 + intensity1 + intensity2, 0.001f);

    float3 lit0 = float3(0.0);
    if (intensity0 > 0.0) {
        float shading0 = (dot(normal, -uniforms.lightDirection.xyz) * 0.5 + 0.5) + shadingShift;
        float shadowStep = linearstep(-1.0 + toony, 1.0 - toony, shading0);
        lit0 = mix(shadeColor, baseColor.rgb, shadowStep) * uniforms.lightColor.xyz * (intensity0 / totalIntensity);
    }

    float3 lit1 = float3(0.0);
    if (intensity1 > 0.0) {
        float shading1 = (dot(normal, -uniforms.light1Direction.xyz) * 0.5 + 0.5) + shadingShift;
        float shadowStep1 = linearstep(-1.0 + toony, 1.0 - toony, shading1);
        lit1 = mix(shadeColor, baseColor.rgb, shadowStep1) * uniforms.light1Color.xyz * (intensity1 / totalIntensity);
    }

    float3 lit2 = float3(0.0);
    if (intensity2 > 0.0) {
        float shading2 = (dot(normal, -uniforms.light2Direction.xyz) * 0.5 + 0.5) + shadingShift;
        float shadowStep2 = linearstep(-1.0 + toony, 1.0 - toony, shading2);
        lit2 = mix(shadeColor, baseColor.rgb, shadowStep2) * uniforms.light2Color.xyz * (intensity2 / totalIntensity);
    }

    float3 litColor = (lit0 + lit1 + lit2) * uniforms.lightNormalizationFactor + (uniforms.ambientColor.xyz * baseColor.rgb);

    // Emissive
    float3 emissive = float3(material.emissiveR, material.emissiveG, material.emissiveB);
    if (material.hasEmissiveTexture > 0) {
        emissive *= emissiveTexture.sample(textureSampler, uv).rgb;
    }
    litColor += emissive;

    // MatCap
    if (material.hasMatcapTexture > 0) {
        litColor += matcapTexture.sample(textureSampler, calculateMatCapUV(viewNormal)).rgb * float3(material.matcapR, material.matcapG, material.matcapB);
    }

    // Rim lighting
    float3 rimColorFactor = float3(material.parametricRimColorR, material.parametricRimColorG, material.parametricRimColorB);
    if (any(rimColorFactor > 0.0)) {
        float3 Vv = normalize(in.viewDirection);
        float3 viewDirViewSpace = normalize((uniforms.viewMatrix * float4(Vv, 0.0)).xyz);
        float NdotV = saturate(dot(viewNormal, viewDirViewSpace));
        float rimF = pow(saturate((1.0 - NdotV) + material.parametricRimLiftFactor), material.parametricRimFresnelPowerFactor);
        float3 rimColor = rimColorFactor * rimF;
        if (material.hasRimMultiplyTexture > 0) {
            rimColor *= rimMultiplyTexture.sample(textureSampler, uv).r;
        }
        litColor += mix(rimColor * uniforms.lightColor.xyz, rimColor, material.rimLightingMixFactor);
    }

    litColor = saturate(max(litColor, baseColor.rgb * 0.08));
    return float4(litColor, baseColor.a);
}
