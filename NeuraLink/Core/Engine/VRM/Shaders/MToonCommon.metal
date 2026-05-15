#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 normalMatrix;
    float4 lightDirection;
    float4 lightColor;
    float4 ambientColor;
    float4 light1Direction;
    float4 light1Color;
    float4 light2Direction;
    float4 light2Color;
    float4 viewportSize;
    float4 nearFarPlane;
    int debugUVs;
    float lightNormalizationFactor;
    float _padding2;
    float _padding3;
    int toonBands;
    float _padding5;
    float _padding6;
    float _padding7;
};

struct MToonMaterial {
    float4 baseColorFactor;
    float shadeColorR;
    float shadeColorG;
    float shadeColorB;
    float shadingToonyFactor;
    float shadingShiftFactor;
    float emissiveR;
    float emissiveG;
    float emissiveB;
    float metallicFactor;
    float roughnessFactor;
    float giIntensityFactor;
    float shadingShiftTextureScale;
    float matcapR;
    float matcapG;
    float matcapB;
    int hasMatcapTexture;
    float parametricRimColorR;
    float parametricRimColorG;
    float parametricRimColorB;
    float parametricRimFresnelPowerFactor;
    float parametricRimLiftFactor;
    float rimLightingMixFactor;
    int hasRimMultiplyTexture;
    float _padding1;
    float outlineWidthFactor;
    float outlineColorR;
    float outlineColorG;
    float outlineColorB;
    float outlineLightingMixFactor;
    float outlineMode;
    int hasOutlineWidthMultiplyTexture;
    float _padding2;
    float uvAnimationScrollXSpeedFactor;
    float uvAnimationScrollYSpeedFactor;
    float uvAnimationRotationSpeedFactor;
    float time;
    int hasUvAnimationMaskTexture;
    int hasBaseColorTexture;
    int hasShadeMultiplyTexture;
    int hasShadingShiftTexture;
    int hasNormalTexture;
    int hasEmissiveTexture;
    uint32_t alphaMode;
    float alphaCutoff;
    uint32_t vrmVersion;
    float uvOffsetX;
    float uvOffsetY;
    float uvScale;
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
    float4 color [[attribute(3)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 texCoord;
    float2 animatedTexCoord;
    float4 color;
    float3 viewDirection;
    float3 viewNormal;
};

// UV Animation utility function
static inline float2 animateUV(float2 uv, constant MToonMaterial& material) {
    float2 result = uv;
    if (material.uvAnimationRotationSpeedFactor != 0.0) {
        float angle = material.uvAnimationRotationSpeedFactor * material.time;
        float2 center = float2(0.5, 0.5);
        float2 translated = result - center;
        float cosAngle = cos(angle);
        float sinAngle = sin(angle);
        float2x2 rotationMatrix = float2x2(float2(cosAngle, -sinAngle), float2(sinAngle, cosAngle));
        result = rotationMatrix * translated + center;
    }
    result.x += material.uvAnimationScrollXSpeedFactor * material.time;
    result.y += material.uvAnimationScrollYSpeedFactor * material.time;
    return result;
}

// VRMC_materials_mtoon-1.0 spec matcap UV.
// Uses a world-view tangent basis so the matcap stays stable as the camera rotates.
// The 0.495 scale avoids sampling at the exact texture border.
static inline float2 calculateMatCapUV(float3 normal, float3 viewDir) {
    float3 worldViewX = normalize(float3(viewDir.z, 0.0f, -viewDir.x));
    float3 worldViewY = cross(viewDir, worldViewX);
    return float2(dot(worldViewX, normal), dot(worldViewY, normal)) * 0.495f + 0.5f;
}

// VRM MToon spec uses linearstep
static inline float linearstep(float a, float b, float t) {
    float range = b - a;
    if (range <= 0.0001) {
        return t >= b ? 1.0 : 0.0;
    }
    return saturate((t - a) / range);
}
