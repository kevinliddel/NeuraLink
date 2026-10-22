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

    float outlineWidth = material.outlineWidthFactor
                       * mtoonOutlineWidthMask(outlineWidthMultiplyTexture, textureSampler, in.texCoord, material);

    float3 worldNormal = normalize((uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
    float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                    uniforms.viewMatrix[1].xyz,
                                    uniforms.viewMatrix[2].xyz);
    float3 cameraPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
    float3 worldPos = (uniforms.modelMatrix * float4(in.position, 1.0)).xyz;
    float3 viewDir = normalize(cameraPos - worldPos);

    if (material.outlineMode == 1.0 || material.outlineMode == 2.0) {
        float viewDepth = -(uniforms.viewMatrix * float4(worldPos, 1.0)).z;
        worldPos += mtoonOutlineOffset(worldNormal, outlineWidth, material.outlineMode,
                                       viewDepth, uniforms.projectionMatrix[1][1]);
    }
    out.worldPosition = worldPos;
    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * float4(worldPos, 1.0);
    // Where the shell meets its own surface the surface must win (three-vrm).
    out.position.z += 1e-6 * out.position.w;

    out.worldNormal = worldNormal;
    out.viewNormal = normalize((uniforms.viewMatrix * uniforms.normalMatrix * float4(in.normal, 0.0)).xyz);
    out.texCoord = in.texCoord;
    out.animatedTexCoord = animateUV(in.texCoord, material);
    out.color = in.color;
    out.viewDirection = viewDir;

    return out;
}

// Outline fragment shader.
// spec: outlineColor_final = outlineColor × lerp(1, lighting, outlineLightingMixFactor)
// 0 = pure outline colour (unaffected by light), 1 = outline tinted by lighting.
fragment float4 mtoon_outline_fragment(VertexOut in [[stage_in]],
                                constant MToonMaterial& material [[buffer(8)]],
                                constant Uniforms& uniforms [[buffer(1)]],
                                texture2d<float> baseColorTexture [[texture(0)]],
                                sampler textureSampler [[sampler(0)]]) {
    // Same alpha cutout as the main pass: the hull of alpha-hidden geometry
    // must not paint solid outline-colored panels where the surface itself
    // was discarded.
    float alpha = material.baseColorFactor.a;
    if (material.hasBaseColorTexture > 0) {
        alpha *= baseColorTexture.sample(textureSampler, in.texCoord).a;
    }
    if (material.alphaMode == 1 && alpha < material.alphaCutoff) { discard_fragment(); }
    if (material.alphaMode == 2 && alpha < 0.004) { discard_fragment(); }

    float3 outlineMaterial = float3(material.outlineColorR,
                                    material.outlineColorG,
                                    material.outlineColorB);

    // Directional lighting contribution at this surface
    float3 normal  = normalize(in.worldNormal);
    float  ndotl   = max(dot(normal, -uniforms.lightDirection.xyz), 0.0);
    float3 lighting = uniforms.lightColor.xyz * ndotl * uniforms.lightNormalizationFactor;

    // spec: lerp(1, lighting, factor) — 0=pure, 1=lit
    float3 outlineColor = outlineMaterial * mix(float3(1.0), lighting, material.outlineLightingMixFactor);
    return float4(outlineColor, material.alphaMode == 2 ? alpha : 1.0);
}
