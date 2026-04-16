#include <metal_stdlib>
using namespace metal;

struct Uniforms {
 float4x4 modelMatrix;
 float4x4 viewMatrix;
 float4x4 projectionMatrix;
 float4x4 normalMatrix;
 // Light 0 (key light) - using float4 for Swift SIMD4 alignment
 float4 lightDirection;        // xyz = direction, w = padding
 float4 lightColor;            // xyz = color, w = padding
 float4 ambientColor;          // xyz = color, w = padding
 // Light 1 (fill light)
 float4 light1Direction;       // xyz = direction, w = padding
 float4 light1Color;           // xyz = color, w = padding
 // Light 2 (rim/back light)
 float4 light2Direction;       // xyz = direction, w = padding
 float4 light2Color;           // xyz = color, w = padding
 // Other fields - packed into float4 for alignment
 float4 viewportSize;          // xy = size, zw = padding
 float4 nearFarPlane;          // x = near, y = far, zw = padding
 int debugUVs;
 float lightNormalizationFactor;
 float _padding2;
 float _padding3;
 int toonBands;
 float _padding5;
 float _padding6;
 float _padding7;
};

// Use packed floats to match Swift struct layout (192 bytes total)
// Note: Metal's float3 has 16-byte alignment which causes padding
struct MToonMaterial {
 // Block 0: 16 bytes - Base material properties
 float4 baseColorFactor;                    // 16 bytes

 // Block 1: 16 bytes - Shade and basic factors (packed float3 + float)
 float shadeColorR;                         // 4 bytes
 float shadeColorG;                         // 4 bytes
 float shadeColorB;                         // 4 bytes
 float shadingToonyFactor;                  // 4 bytes

 // Block 2: 16 bytes - Material factors (float + packed float3)
 float shadingShiftFactor;                  // 4 bytes
 float emissiveR;                           // 4 bytes
 float emissiveG;                           // 4 bytes
 float emissiveB;                           // 4 bytes

 // Block 3: 16 bytes - PBR factors
 float metallicFactor;                      // 4 bytes
 float roughnessFactor;                     // 4 bytes
 float giIntensityFactor;                   // 4 bytes
 float shadingShiftTextureScale;            // 4 bytes

 // Block 4: 16 bytes - MatCap properties (packed float3 + int)
 float matcapR;                             // 4 bytes
 float matcapG;                             // 4 bytes
 float matcapB;                             // 4 bytes
 int hasMatcapTexture;                      // 4 bytes

 // Block 5: 16 bytes - Rim lighting part 1 (packed float3 + float)
 float parametricRimColorR;                 // 4 bytes
 float parametricRimColorG;                 // 4 bytes
 float parametricRimColorB;                 // 4 bytes
 float parametricRimFresnelPowerFactor;     // 4 bytes

 // Block 6: 16 bytes - Rim lighting part 2
 float parametricRimLiftFactor;             // 4 bytes
 float rimLightingMixFactor;                // 4 bytes
 int hasRimMultiplyTexture;                 // 4 bytes
 float _padding1;                           // 4 bytes padding

 // Block 7: 16 bytes - Outline properties part 1 (float + packed float3)
 float outlineWidthFactor;                  // 4 bytes
 float outlineColorR;                       // 4 bytes
 float outlineColorG;                       // 4 bytes
 float outlineColorB;                       // 4 bytes

 // Block 8: 16 bytes - Outline properties part 2
 float outlineLightingMixFactor;            // 4 bytes
 float outlineMode;                         // 4 bytes (0: None, 1: World, 2: Screen)
 int hasOutlineWidthMultiplyTexture;        // 4 bytes
 float _padding2;                           // 4 bytes padding

 // Block 9: 16 bytes - UV Animation
 float uvAnimationScrollXSpeedFactor;       // 4 bytes
 float uvAnimationScrollYSpeedFactor;       // 4 bytes
 float uvAnimationRotationSpeedFactor;      // 4 bytes
 float time;                                // 4 bytes

 // Block 10: 16 bytes - Texture flags
 int hasUvAnimationMaskTexture;             // 4 bytes
 int hasBaseColorTexture;                   // 4 bytes
 int hasShadeMultiplyTexture;               // 4 bytes
 int hasShadingShiftTexture;                // 4 bytes

 // Block 11: 16 bytes - More texture flags and alpha
 int hasNormalTexture;                      // 4 bytes
 int hasEmissiveTexture;                    // 4 bytes
 uint32_t alphaMode;                        // 4 bytes
 float alphaCutoff;                         // 4 bytes

 // Block 12: 16 bytes - Version flag and padding
 uint32_t vrmVersion;                       // 4 bytes (0 = VRM 0.0, 1 = VRM 1.0)
 float _padding3;                           // 4 bytes
 float _padding4;                           // 4 bytes
 float _padding5;                           // 4 bytes
};

struct VertexIn {
 float3 position [[attribute(0)]];
 float3 normal [[attribute(1)]];
 float2 texCoord [[attribute(2)]];
 float4 color [[attribute(3)]];
 uint4 joints [[attribute(4)]];  // Changed to uint4 to match VRMVertex.joints (SIMD4<UInt32>)
 float4 weights [[attribute(5)]];
};

// Must match MToonShader's VertexOut exactly for fragment shader compatibility
struct VertexOut {
 float4 position [[position]];
 float3 worldPosition;
 float3 worldNormal;
 float2 texCoord;
 float2 animatedTexCoord;
 float4 color;
 float3 viewDirection;
 float3 viewNormal; // For MatCap sampling
};

// UV Animation utility function (rotation first, then scroll)
static inline float2 animateUV(float2 uv, constant MToonMaterial& material) {
 float2 result = uv;

 // UV rotation animation around center (0.5, 0.5) - FIRST
 if (material.uvAnimationRotationSpeedFactor != 0.0) {
 float angle = material.uvAnimationRotationSpeedFactor * material.time;
 float2 center = float2(0.5, 0.5);
 float2 translated = result - center;

 float cosAngle = cos(angle);
 float sinAngle = sin(angle);
 float2x2 rotationMatrix = float2x2(
     float2(cosAngle, -sinAngle),
     float2(sinAngle, cosAngle)
 );

 result = rotationMatrix * translated + center;
 }

 // UV scroll animation - SECOND
 result.x += material.uvAnimationScrollXSpeedFactor * material.time;
 result.y += material.uvAnimationScrollYSpeedFactor * material.time;

 return result;
}

// Skinned vertex shader with MToon support
vertex VertexOut skinned_mtoon_vertex(VertexIn in [[stage_in]],
                               constant Uniforms& uniforms [[buffer(1)]],
                               constant MToonMaterial& material [[buffer(8)]],
                               constant float4x4* jointMatrices [[buffer(25)]],
                               device float3* morphedPositions [[buffer(20)]],
                               constant uint& hasMorphed [[buffer(22)]],
                               uint vertexID [[vertex_id]]) {
 VertexOut out;

 // Use morphed positions if available, otherwise use original
 float3 basePosition;
 if (hasMorphed > 0) {
 // Positions from compute shader output (after morph target application)
 basePosition = float3(morphedPositions[vertexID]);
 } else {
 // No morphs - use original position
 basePosition = in.position;
 }

 // Store RAW weights for threshold check (before normalization)
 // This prevents accessing garbage joint indices that have zero/tiny weights
 float4 rawWeights = in.weights;

 // Normalize weights to ensure they sum to 1.0 (prevents partial transforms)
 float4 weights = rawWeights;
 float weightSum = dot(weights, float4(1.0));
 if (weightSum > 1e-6) {
 weights = weights / weightSum;
 } else {
 weights = float4(1.0, 0.0, 0.0, 0.0); // Fallback to first joint
 }

 // Apply skeletal skinning with normalized weights
 // CRITICAL: Use RAW weights for threshold check to avoid accessing garbage joint indices
 float4x4 skinMatrix = float4x4(0.0);
 float threshold = 0.001;

 // Safe buffer limit: clamp to 255 to prevent reading garbage memory
 // This allows valid indices (0-90+) while blocking garbage indices (65535, etc.)
 uint maxJoint = 255;
 uint4 safeJoints = min(in.joints, uint4(maxJoint));

 if (rawWeights[0] > threshold) {
 skinMatrix += jointMatrices[safeJoints[0]] * weights[0];
 }
 if (rawWeights[1] > threshold) {
 skinMatrix += jointMatrices[safeJoints[1]] * weights[1];
 }
 if (rawWeights[2] > threshold) {
 skinMatrix += jointMatrices[safeJoints[2]] * weights[2];
 }
 if (rawWeights[3] > threshold) {
 skinMatrix += jointMatrices[safeJoints[3]] * weights[3];
 }

 // Fallback: if skinMatrix is zero (no weights passed threshold), use first joint
 if (skinMatrix[0][0] == 0.0 && skinMatrix[1][1] == 0.0 && skinMatrix[2][2] == 0.0) {
 skinMatrix = jointMatrices[safeJoints[0]];
 }

 // Apply skinning to position and normal (using morphed base position if available)
 float4 skinnedPosition = skinMatrix * float4(basePosition, 1.0);
 float3 skinnedNormal = (skinMatrix * float4(in.normal, 0.0)).xyz;

 // SANITY CHECK: Detect NaN/Inf or extreme skinned positions and fall back to original
 // This catches cases where joint indices point to garbage memory or matrix is corrupted
 bool posHasNaN = any(isnan(skinnedPosition.xyz)) || any(isinf(skinnedPosition.xyz));
 bool posHasExtreme = length(skinnedPosition.xyz) > 50.0;  // Reasonable limit for humanoid (within 50 units of origin)
 bool normalHasNaN = any(isnan(skinnedNormal)) || any(isinf(skinnedNormal));
 if (posHasNaN || posHasExtreme || normalHasNaN) {
 // Fall back to original position (no skinning)
 skinnedPosition = float4(basePosition, 1.0);
 skinnedNormal = in.normal;
 }
 skinnedNormal = normalize(skinnedNormal);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 out.worldPosition = worldPos.xyz;

 // Transform normal to world space
 out.worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 // Calculate view direction (from vertex to camera)
 // Extract camera world position from view matrix: cameraPos = -R^T * translation
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraWorldPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);

 // Calculate view-space normal for MatCap
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;  // Will be animated in fragment shader if needed
 out.color = in.color;

 return out;
}

// Simplified skinned vertex shader for debugging
vertex VertexOut skinned_vertex(VertexIn in [[stage_in]],
                         constant Uniforms& uniforms [[buffer(1)]],
                         constant float4x4* jointMatrices [[buffer(25)]],
                         uint vertexID [[vertex_id]]) {
 VertexOut out;

 // Store RAW weights for threshold check
 float4 rawWeights = in.weights;

 // Normalize weights to ensure they sum to 1.0 (prevents partial transforms)
 float4 weights = rawWeights;
 float weightSum = dot(weights, float4(1.0));
 if (weightSum > 1e-6) {
 weights = weights / weightSum;
 } else {
 weights = float4(1.0, 0.0, 0.0, 0.0); // Fallback to first joint
 }

 // Apply skeletal skinning - use RAW weights for threshold check
 float4x4 skinMatrix = float4x4(0.0);
 float threshold = 0.001;

 // Safe buffer limit: clamp to 255 to prevent reading garbage memory
 uint maxJoint = 255;
 uint4 safeJoints = min(in.joints, uint4(maxJoint));

 if (rawWeights[0] > threshold) {
 skinMatrix += jointMatrices[safeJoints[0]] * weights[0];
 }
 if (rawWeights[1] > threshold) {
 skinMatrix += jointMatrices[safeJoints[1]] * weights[1];
 }
 if (rawWeights[2] > threshold) {
 skinMatrix += jointMatrices[safeJoints[2]] * weights[2];
 }
 if (rawWeights[3] > threshold) {
 skinMatrix += jointMatrices[safeJoints[3]] * weights[3];
 }

 // Fallback: if skinMatrix is zero, use first joint
 if (skinMatrix[0][0] == 0.0 && skinMatrix[1][1] == 0.0 && skinMatrix[2][2] == 0.0) {
 skinMatrix = jointMatrices[safeJoints[0]];
 }

 // Apply skinning to position and normal
 float4 skinnedPosition = skinMatrix * float4(in.position, 1.0);
 float3 skinnedNormal = (skinMatrix * float4(in.normal, 0.0)).xyz;

 // SANITY CHECK: Detect NaN/Inf or extreme skinned positions and fall back to original
 bool posHasNaN = any(isnan(skinnedPosition.xyz)) || any(isinf(skinnedPosition.xyz));
 bool posHasExtreme = length(skinnedPosition.xyz) > 50.0;
 bool normalHasNaN = any(isnan(skinnedNormal)) || any(isinf(skinnedNormal));
 if (posHasNaN || posHasExtreme || normalHasNaN) {
 skinnedPosition = float4(in.position, 1.0);
 skinnedNormal = in.normal;
 }
 skinnedNormal = normalize(skinnedNormal);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 out.worldPosition = worldPos.xyz;

 // Transform normal to world space
 out.worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 // Calculate view direction - extract camera world position from view matrix
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraWorldPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);

 // Calculate view-space normal for MatCap
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;
 out.color = in.color;

 return out;
}

// Skinned MToon outline vertex shader (inverted hull technique)
vertex VertexOut skinned_mtoon_outline_vertex(VertexIn in [[stage_in]],
                                              constant Uniforms& uniforms [[buffer(1)]],
                                              constant MToonMaterial& material [[buffer(8)]],
                                              constant float4x4* jointMatrices [[buffer(25)]]) {
 VertexOut out;

 // Store RAW weights for threshold check
 float4 rawWeights = in.weights;

 // Normalize weights to ensure they sum to 1.0 (prevents partial transforms)
 float4 weights = rawWeights;
 float weightSum = dot(weights, float4(1.0));
 if (weightSum > 1e-6) {
 weights = weights / weightSum;
 } else {
 weights = float4(1.0, 0.0, 0.0, 0.0); // Fallback to first joint
 }

 // Apply skeletal skinning - use RAW weights for threshold check
 float4x4 skinMatrix = float4x4(0.0);
 float threshold = 0.001;

 // Safe buffer limit: clamp to 255 to prevent reading garbage memory
 uint maxJoint = 255;
 uint4 safeJoints = min(in.joints, uint4(maxJoint));

 if (rawWeights[0] > threshold) skinMatrix += jointMatrices[safeJoints[0]] * weights[0];
 if (rawWeights[1] > threshold) skinMatrix += jointMatrices[safeJoints[1]] * weights[1];
 if (rawWeights[2] > threshold) skinMatrix += jointMatrices[safeJoints[2]] * weights[2];
 if (rawWeights[3] > threshold) skinMatrix += jointMatrices[safeJoints[3]] * weights[3];

 // Fallback: if skinMatrix is zero, use first joint
 if (skinMatrix[0][0] == 0.0 && skinMatrix[1][1] == 0.0 && skinMatrix[2][2] == 0.0) {
 skinMatrix = jointMatrices[safeJoints[0]];
 }

 // Apply skinning to position and normal
 float4 skinnedPosition = skinMatrix * float4(in.position, 1.0);
 float3 skinnedNormal = (skinMatrix * float4(in.normal, 0.0)).xyz;

 // SANITY CHECK: Detect NaN/Inf or extreme skinned positions and fall back to original
 bool posHasNaN = any(isnan(skinnedPosition.xyz)) || any(isinf(skinnedPosition.xyz));
 bool posHasExtreme = length(skinnedPosition.xyz) > 50.0;
 bool normalHasNaN = any(isnan(skinnedNormal)) || any(isinf(skinnedNormal));
 if (posHasNaN || posHasExtreme || normalHasNaN) {
 skinnedPosition = float4(in.position, 1.0);
 skinnedNormal = in.normal;
 }
 skinnedNormal = normalize(skinnedNormal);

 // Transform to world space
 float4 worldPos = uniforms.modelMatrix * skinnedPosition;
 float3 worldNormal = normalize((uniforms.normalMatrix * float4(skinnedNormal, 0.0)).xyz);

 // Get outline width from material
 float outlineWidth = material.outlineWidthFactor;

 // Extract camera world position from view matrix: cameraPos = -R^T * translation
 // Done once at the start for use in both outline modes and view direction
 float3x3 viewRotation = float3x3(uniforms.viewMatrix[0].xyz,
                                   uniforms.viewMatrix[1].xyz,
                                   uniforms.viewMatrix[2].xyz);
 float3 cameraWorldPos = -(transpose(viewRotation) * uniforms.viewMatrix[3].xyz);

 // Calculate view direction
 float3 viewDir = normalize(cameraWorldPos - worldPos.xyz);

 // Apply outline extrusion along normal
 // outlineMode: 0=none, 1=worldCoordinates, 2=screenCoordinates
 // Must match MToonShader.metal for visual consistency
 if (material.outlineMode == 1) {
  // World coordinates: width scales with camera distance (matches non-skinned)
  float distanceScale = length(worldPos.xyz - cameraWorldPos) * 0.01;
  worldPos.xyz += worldNormal * outlineWidth * distanceScale;
 } else if (material.outlineMode == 2) {
  // Screen coordinates: fixed pixel width (matches non-skinned NDC approach)
  float4 clipPos = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
  float3 viewNormal = normalize((uniforms.viewMatrix * float4(worldNormal, 0.0)).xyz);
  float2 screenNormal = normalize(viewNormal.xy);
  float2 pixelsToNDC = 2.0 / uniforms.viewportSize.xy;
  float2 offsetNDC = screenNormal * outlineWidth * pixelsToNDC;
  clipPos.xy += offsetNDC * clipPos.w;
  out.position = clipPos;
  out.worldPosition = worldPos.xyz;
  out.worldNormal = worldNormal;
  out.viewDirection = viewDir;
  out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);
  out.texCoord = in.texCoord;
  out.animatedTexCoord = in.texCoord;
  out.color = in.color;
  return out;
 }

 out.worldPosition = worldPos.xyz;
 out.worldNormal = worldNormal;

 // Transform to clip space
 float4 viewPosition = uniforms.viewMatrix * worldPos;
 out.position = uniforms.projectionMatrix * viewPosition;

 // Calculate view direction and view normal
 out.viewDirection = normalize(cameraWorldPos - out.worldPosition);
 out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);

 // Pass through texture coordinates and vertex color
 out.texCoord = in.texCoord;
 out.animatedTexCoord = in.texCoord;
 out.color = in.color;

 return out;
}
