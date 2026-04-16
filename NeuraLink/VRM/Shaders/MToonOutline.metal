#include <metal_stdlib>
#include "MToonCommon.metal"

using namespace metal;

// Outline vertex shader with advanced features
vertex VertexOut mtoon_outline_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(1)]],
                               constant MToonMaterial& material [[buffer(8)]],
                               texture2d<float> outlineWidthMultiplyTexture [[texture(0)]],
                               sampler textureSampler [[sampler(0)]]) {
    VertexOut out;

    float outlineWidth = material.outlineWidthFactor;
    if (material.hasOutlineWidthMultiplyTexture > 0) {
        outlineWidth *= outlineWidthMultiplyTexture.sample(textureSampler, in.texCoord).r;
    }

    float3 worldNormal = normalize((uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
    float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                    uniforms.viewMatrix[1].xyz,
                                    uniforms.viewMatrix[2].xyz);
    float3 cameraPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
    float3 worldPos = (uniforms.modelMatrix * float4(in.position, 1.0)).xyz;
    float3 viewDir = normalize(cameraPos - worldPos);

    if (material.outlineMode == 1.0) {
        float distanceScale = length(worldPos - cameraPos) * 0.01;
        worldPos += worldNormal * outlineWidth * distanceScale;
        out.worldPosition = worldPos;
        out.position = uniforms.projectionMatrix * uniforms.viewMatrix * float4(worldPos, 1.0);
    } else if (material.outlineMode == 2.0) {
        float4 worldPos4 = uniforms.modelMatrix * float4(in.position, 1.0);
        out.worldPosition = worldPos4.xyz;
        float4 clipPos = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos4;
        float3 viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
        float2 screenNormal = normalize(viewNormal.xy);
        float2 offsetNDC = screenNormal * outlineWidth * (2.0 / uniforms.viewportSize.xy);
        clipPos.xy += offsetNDC * clipPos.w;
        out.position = clipPos;
    } else {
        float4 worldPos4 = uniforms.modelMatrix * float4(in.position, 1.0);
        out.worldPosition = worldPos4.xyz;
        out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos4;
    }

    out.worldNormal = worldNormal;
    out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
    out.texCoord = in.texCoord;
    out.animatedTexCoord = animateUV(in.texCoord, material);
    out.color = in.color;
    out.viewDirection = viewDir;

    return out;
}

// Advanced outline fragment shader
fragment float4 mtoon_outline_fragment(VertexOut in [[stage_in]],
                                constant MToonMaterial& material [[buffer(8)]],
                                constant Uniforms& uniforms [[buffer(1)]]) {
    float3 outlineColor = float3(material.outlineColorR, material.outlineColorG, material.outlineColorB);
    if (material.outlineLightingMixFactor < 1.0) {
        float3 lightInfluence = uniforms.lightColor.xyz * uniforms.ambientColor.xyz;
        outlineColor = mix(outlineColor * lightInfluence, outlineColor, material.outlineLightingMixFactor);
    }
    return float4(outlineColor, 1.0);
}
