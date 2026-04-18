#include <metal_stdlib>
#include "MToonCommon.metal"

using namespace metal;

// Debug fragment shaders for visualizing individual MToon components
fragment float4 mtoon_debug_nl(VertexOut in [[stage_in]],
                        constant MToonMaterial& material [[buffer(8)]],
                        constant Uniforms& uniforms [[buffer(1)]]) {
    float3 normal = normalize(in.worldNormal);
    float nl = saturate(dot(normal, -uniforms.lightDirection.xyz));
    return float4(nl, nl, nl, 1.0);
}

fragment float4 mtoon_debug_ramp(VertexOut in [[stage_in]],
                          constant MToonMaterial& material [[buffer(8)]],
                          constant Uniforms& uniforms [[buffer(1)]],
                          texture2d<float> shadingShiftTexture [[texture(2)]],
                          sampler textureSampler [[sampler(0)]]) {
    float3 normal = normalize(in.worldNormal);
    float nl = saturate(dot(normal, -uniforms.lightDirection.xyz));

    float shadingShift = material.shadingShiftFactor;
    if (material.hasShadingShiftTexture > 0) {
        float shiftTexValue = shadingShiftTexture.sample(textureSampler, in.texCoord).r;
        shadingShift += (shiftTexValue * 2.0 - 1.0) * material.shadingShiftTextureScale;
    }

    float shading = nl + shadingShift;
    float ramp = linearstep(-1.0 + material.shadingToonyFactor, 1.0 - material.shadingToonyFactor, shading);
    return float4(ramp, ramp, ramp, 1.0);
}

fragment float4 mtoon_debug_rim(VertexOut in [[stage_in]],
                         constant MToonMaterial& material [[buffer(8)]],
                         constant Uniforms& uniforms [[buffer(1)]]) {
    float3 rimColorFactor = float3(material.parametricRimColorR, material.parametricRimColorG, material.parametricRimColorB);
    if (any(rimColorFactor <= 0.0)) {
        return float4(0, 0, 0, 1);
    }

    float3 Nv = in.viewNormal;
    float3 Vv = normalize(in.viewDirection);
    float3 viewDirViewSpace = normalize((uniforms.viewMatrix * float4(Vv, 0.0)).xyz);
    float NdotV = saturate(dot(Nv, viewDirViewSpace));
    float vf = 1.0 - NdotV;
    float rimF = pow(saturate(vf + material.parametricRimLiftFactor),
                   material.parametricRimFresnelPowerFactor);
    return float4(rimF, rimF, rimF, 1.0);
}

fragment float4 mtoon_debug_matcap_uv(VertexOut in [[stage_in]]) {
    float3 normal  = normalize(in.worldNormal);
    float3 viewDir = normalize(in.viewDirection);
    float2 matcapUV = calculateMatCapUV(normal, viewDir);
    return float4(matcapUV.x, matcapUV.y, 0.0, 1.0);
}

fragment float4 mtoon_debug_outline_width(VertexOut in [[stage_in]],
                                   constant MToonMaterial& material [[buffer(8)]]) {
    float width = material.outlineWidthFactor * 10.0; // Scale for visibility
    return float4(width, width, width, 1.0);
}
