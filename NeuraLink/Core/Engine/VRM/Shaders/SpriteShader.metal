#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

struct SpriteVertex {
 float2 position [[attribute(0)]];  // Quad vertex position (-0.5 to 0.5)
 float2 texCoord [[attribute(1)]];  // Texture coordinates (0 to 1)
};

struct SpriteInstance {
 float4x4 modelMatrix;      // Transform matrix (includes position, rotation, scale)
 float4 tintColor;          // Tint color (default: white)
 float2 texOffset;          // Texture atlas offset (for sprite sheets)
 float2 texScale;           // Texture atlas scale (default: 1,1)
};

struct SpriteUniforms {
 float4x4 viewProjectionMatrix;  // Combined view-projection matrix
 float2 viewportSize;            // For screen-space calculations
 float _padding1;
 float _padding2;
};

struct VertexOut {
 float4 position [[position]];
 float2 texCoord;
 float4 tintColor;
};

// MARK: - Vertex Shader (Non-Instanced)

vertex VertexOut sprite_vertex(
 SpriteVertex in [[stage_in]],
 constant SpriteUniforms &uniforms [[buffer(1)]],
 constant SpriteInstance &instance [[buffer(2)]]
) {
 VertexOut out;

 // Transform quad vertex to world space
 float4 worldPos = instance.modelMatrix * float4(in.position, 0.0, 1.0);

 // Project to clip space
 out.position = uniforms.viewProjectionMatrix * worldPos;

 // Apply texture atlas offset and scale
 out.texCoord = in.texCoord * instance.texScale + instance.texOffset;

 // Pass through tint color
 out.tintColor = instance.tintColor;

 return out;
}

// MARK: - Vertex Shader (Instanced)

vertex VertexOut sprite_instanced_vertex(
 SpriteVertex in [[stage_in]],
 constant SpriteUniforms &uniforms [[buffer(1)]],
 constant SpriteInstance *instances [[buffer(2)]],
 uint instanceID [[instance_id]]
) {
 VertexOut out;

 SpriteInstance instance = instances[instanceID];

 // Transform quad vertex to world space
 float4 worldPos = instance.modelMatrix * float4(in.position, 0.0, 1.0);

 // Project to clip space
 out.position = uniforms.viewProjectionMatrix * worldPos;

 // Apply texture atlas offset and scale
 out.texCoord = in.texCoord * instance.texScale + instance.texOffset;

 // Pass through tint color
 out.tintColor = instance.tintColor;

 return out;
}

// MARK: - Fragment Shader

fragment float4 sprite_fragment(
 VertexOut in [[stage_in]],
 texture2d<float> spriteTexture [[texture(0)]],
 sampler spriteSampler [[sampler(0)]]
) {
 // Sample sprite texture
 float4 texColor = spriteTexture.sample(spriteSampler, in.texCoord);

 // Apply tint
 float4 finalColor = texColor * in.tintColor;

 // Alpha test - discard fully transparent pixels
 if (finalColor.a < 0.01) {
 discard_fragment();
 }

 return finalColor;
}

// MARK: - Premultiplied Alpha Variant

fragment float4 sprite_premultiplied_fragment(
 VertexOut in [[stage_in]],
 texture2d<float> spriteTexture [[texture(0)]],
 sampler spriteSampler [[sampler(0)]]
) {
 // Sample sprite texture (already premultiplied)
 float4 texColor = spriteTexture.sample(spriteSampler, in.texCoord);

 // Apply tint (preserve premultiplied alpha)
 float4 finalColor;
 finalColor.rgb = texColor.rgb * in.tintColor.rgb;
 finalColor.a = texColor.a * in.tintColor.a;

 // Alpha test
 if (finalColor.a < 0.01) {
 discard_fragment();
 }

 return finalColor;
}
