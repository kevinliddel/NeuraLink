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
    float normalScale;
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
    // Block 13: appearance recolour (see MToonShader.swift)
    float recolorHueShift;
    float recolorSaturation;
    float recolorBrightness;
    int recolorEnabled;
};

// ── Appearance recolour (character customization) ────────────────
// HSV shift of the sampled base/shade colour. Runs in linear space (the
// textures are sRGB-decoded on sample) — a hue rotation is hue-preserving
// either way, and saturation/brightness scale is what the sliders promise.
static inline float3 nl_rgb2hsv(float3 c) {
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = c.g < c.b ? float4(c.bg, K.wz) : float4(c.gb, K.xy);
    float4 q = c.r < p.x ? float4(p.xyw, c.r) : float4(c.r, p.yzx);
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

static inline float3 nl_hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

static inline float3 nl_applyRecolor(float3 rgb, constant MToonMaterial& m) {
    if (m.recolorEnabled == 0) { return rgb; }
    float3 hsv = nl_rgb2hsv(rgb);
    hsv.x = fract(hsv.x + m.recolorHueShift);
    hsv.y = clamp(hsv.y * m.recolorSaturation, 0.0, 1.0);
    hsv.z = hsv.z * m.recolorBrightness;
    return nl_hsv2rgb(hsv);
}

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

// Hemisphere GI: ambient × (1 ± this) along world up (MToonMain).
constant float kMToonHemisphere = 0.35;

// ── Avatar self-shadow (VRMRenderer+AvatarShadow) ───────────────
/// Mirrors `AvatarShadowParams` (Swift).
struct AvatarShadowParams {
    float4x4 lightViewProjection;
    float normalOffset;
    float depthBias;
    float texelSize;
    int enabled;
};

/// How much key light reaches `worldPos`: 1 lit, 0 in the avatar's own
/// shadow. Nine hardware 2×2 compares (a 4×4-texel footprint) soften the
/// edge enough for the toon step without blurring the shape.
static inline float avatarShadow(depth2d<float> shadowMap, sampler shadowSampler,
                                 constant AvatarShadowParams& params, float3 worldPos, float3 normal) {
    if (params.enabled == 0) { return 1.0; }
    float4 clip = params.lightViewProjection * float4(worldPos + normal * params.normalOffset, 1.0);
    float3 ndc = clip.xyz / clip.w;
    if (any(abs(ndc.xy) > 1.0) || ndc.z < 0.0 || ndc.z > 1.0) { return 1.0; }
    float2 uv = float2(ndc.x * 0.5 + 0.5, -ndc.y * 0.5 + 0.5);
    float depth = ndc.z - params.depthBias;
    float lit = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            lit += shadowMap.sample_compare(shadowSampler, uv + float2(x, y) * params.texelSize, depth);
        }
    }
    return lit / 9.0;
}

// ── Outline (VRMC_materials_mtoon 1.0) ──────────────────────────
// World mode: `width` is meters along the normal. Screen mode: a fraction
// of the half screen height, which three-vrm gets by scaling with
// viewDepth / P[1][1] — so the line keeps its on-screen size at any distance.
static inline float3 mtoonOutlineOffset(float3 worldNormal, float width, float mode,
                                        float viewDepth, float projectionYScale) {
    float scale = (mode == 2.0) ? viewDepth / max(projectionYScale, 1e-4) : 1.0;
    return worldNormal * width * scale;
}

// Width multiplier: VRM 1.0 reads G (spec, three-vrm), VRM 0.x MToon read R.
// Vertex stage, so an explicit LOD.
static inline float mtoonOutlineWidthMask(texture2d<float> widthTexture, sampler textureSampler,
                                          float2 uv, constant MToonMaterial& material) {
    if (material.hasOutlineWidthMultiplyTexture == 0) { return 1.0; }
    float4 sample = widthTexture.sample(textureSampler, uv, level(0));
    return material.vrmVersion == 0 ? sample.r : sample.g;
}

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
