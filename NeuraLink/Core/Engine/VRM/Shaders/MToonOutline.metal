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
                       * mtoonOutlineWidthMask(outlineWidthMultiplyTexture, textureSampler,
                                               mtoonTransformUV(animateUV(in.texCoord, material), material), material);

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
// Spec (UniVRM, three-vrm): outline = outlineColor × lerp(1, litColor,
// outlineLightingMixFactor), where litColor is the surface's own MToon result
// at that point — a dark-hair outline is a darker hair colour, not black.
// This pass binds only the base texture, so the shade side is
// shadeColor × base when the material multiplies its shade by a texture
// (VRoid binds the base texture there) — close to the main pass, not exact.
fragment float4 mtoon_outline_fragment(VertexOut in [[stage_in]],
                                constant MToonMaterial& material [[buffer(8)]],
                                constant Uniforms& uniforms [[buffer(1)]],
                                texture2d<float> baseColorTexture [[texture(0)]],
                                sampler textureSampler [[sampler(0)]]) {
    // Same alpha cutout as the main pass: the hull of alpha-hidden geometry
    // must not paint solid outline-colored panels where the surface itself
    // was discarded.
    float4 base = material.baseColorFactor;
    if (material.hasBaseColorTexture > 0) {
        base *= baseColorTexture.sample(textureSampler, mtoonTransformUV(animateUV(in.texCoord, material), material));
    }
    if (material.alphaMode == 1 && base.a < material.alphaCutoff) { discard_fragment(); }
    if (material.alphaMode == 2 && base.a < 0.004) { discard_fragment(); }
    float3 baseRGB = nl_applyRecolor(base.rgb, material);

    float3 shade = float3(material.shadeColorR, material.shadeColorG, material.shadeColorB);
    if (material.hasShadeMultiplyTexture > 0) { shade *= baseRGB; }

    // The surface's lit colour: the same toon step per light as the main pass.
    float3 normal = normalize(in.worldNormal);
    float toony = material.shadingToonyFactor;
    float total = max(uniforms.lightColor.w + uniforms.light1Color.w + uniforms.light2Color.w, 0.001f);
    float3 lit = float3(0.0);
    float4 colors[3] = { uniforms.lightColor, uniforms.light1Color, uniforms.light2Color };
    float3 directions[3] = { uniforms.lightDirection.xyz, uniforms.light1Direction.xyz, uniforms.light2Direction.xyz };
    for (int i = 0; i < 3; i++) {
        if (colors[i].w <= 0.0) { continue; }
        float shading = dot(normal, -directions[i]) + material.shadingShiftFactor;
        float lightStep = linearstep(-1.0 + toony, 1.0 - toony, shading);
        lit += mix(shade, baseRGB, lightStep) * colors[i].xyz * (colors[i].w / total);
    }
    float3 gi = mix(mtoonAmbientAlong(uniforms, normal), uniforms.ambientColor.xyz,
                    saturate(1.0 - material.giIntensityFactor));
    float3 surface = lit * uniforms.lightNormalizationFactor + gi * baseRGB;

    float3 outlineColor = float3(material.outlineColorR, material.outlineColorG, material.outlineColorB)
                        * mix(float3(1.0), surface, material.outlineLightingMixFactor);
    return float4(saturate(outlineColor), material.alphaMode == 2 ? base.a : 1.0);
}
