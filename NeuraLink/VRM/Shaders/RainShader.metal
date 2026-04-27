//
//  RainShader.metal
//  NeuraLink
//
//  Rain-on-glass / camera-lens effect.
//  Two passes:
//    1. rain_watermap  (compute) — writes per-pixel sphere-normal data from CPU drop list.
//    2. rain_vertex / rain_fragment (render) — fullscreen liquid-glass overlay.

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared structures

/// Per-drop data uploaded from Swift each frame. Must match RainDropGPU in Swift.
struct RainDropGPU {
    float2 position;   // normalised [0,1], y=0 at top
    float  radius;     // normalised to water-map height
    float  alpha;      // [0,1]
    float  spreadX;
    float  spreadY;
    float2 _pad;
};  // 32 bytes

/// Fragment-pass uniforms. Must match RainUniformsGPU in Swift.
struct RainUniforms {
    float alphaMultiply;
    float alphaSubtract;
    float brightness;
    float intensity;       // overall rain visibility [0,1]
    float waterMapWidth;
    float waterMapHeight;
};  // 24 bytes

/// Uniforms for 3D world rain. Must match RainWorldUniforms in Swift.
struct RainWorldUniforms {
    float4x4 viewProjection; // 0..64
    float3   cameraPos;      // 64..76 (16-byte aligned)
    float    time;           // 80..84
    float    intensity;      // 84..88
    float2   wind;           // 88..96 (windX, windZ)
}; // 96 bytes

struct Rain3DParticleGPU {
    float4 spawnXZ_phase_speed; // x,z = spawn, y = phase, w = speed
    float4 color;               // rgba
}; // 32 bytes

// MARK: - Compute: generate water map

/// Writes a per-pixel water map (RGBA8Unorm):
///   R = sphere-normal Y refraction (0.5 = neutral)
///   G = sphere-normal X refraction (0.5 = neutral)
///   B = drop depth / thickness
///   A = drop alpha (0 = empty pixel)
kernel void rain_watermap(
    texture2d<float, access::write> waterMap  [[texture(0)]],
    device const RainDropGPU*       drops     [[buffer(0)]],
    constant uint&                  dropCount [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint2 size = uint2(waterMap.get_width(), waterMap.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;

    const float2 uv = float2(gid) / float2(size);  // y=0 at top, matches drop.position

    float4 result = float4(0.0);

    for (uint i = 0; i < dropCount; i++) {
        const RainDropGPU d = drops[i];
        if (d.radius <= 0.0f || d.alpha <= 0.0f) continue;

        // Pixel-space relative position (corrects for non-square aspect)
        const float2 pixRel    = (uv - d.position) * float2(size);
        const float  pixRadius = d.radius * float(size.y);

        // Elliptical spread (JS drawDrop dimensions: w = r*2*(spreadX+1), h = r*2*1.5*(spreadY+1))
        const float2 shaped = float2(
            pixRel.x / (d.spreadX + 1.0f),
            pixRel.y / (d.spreadY * 1.5f + 1.0f)
        );
        const float r2 = dot(shaped, shaped) / (pixRadius * pixRadius);
        if (r2 >= 1.0f) continue;

        const float sqrtR2 = sqrt(r2);
        const float nzVal  = sqrt(max(1.0f - r2, 0.0f));

        // Surface normal in drop space
        const float2 normDir = shaped / max(pixRadius * max(sqrtR2, 0.001f), 0.001f);
        const float  nx = normDir.x;
        const float  ny = normDir.y;

        // Encode normals as the makeDropColor JS texture does:
        //   R = refY (-ny*nz*0.5+0.5), G = refX (-nx*nz*0.5+0.5), B = depth (nz)
        const float refY  = -ny * nzVal * 0.5f + 0.5f;
        const float refX  = -nx * nzVal * 0.5f + 0.5f;
        const float depth = nzVal;

        // Smooth alpha falloff towards edge
        const float a = smoothstep(1.0f, 0.0f, sqrtR2) * d.alpha;
        const float w = a * (1.0f - result.a);

        result.r += refY  * w;
        result.g += refX  * w;
        result.b += depth * w;
        result.a  = min(result.a + w, 1.0f);
    }

    // Neutral refraction for empty pixels
    if (result.a < 0.001f) {
        waterMap.write(float4(0.5f, 0.5f, 0.0f, 0.0f), gid);
        return;
    }
    waterMap.write(result, gid);
}

// MARK: - Vertex: fullscreen triangle

struct RainVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex RainVSOut rain_vertex(uint vid [[vertex_id]]) {
    constexpr float2 pos[3] = {
        float2(-1.0f, -3.0f),
        float2(-1.0f,  1.0f),
        float2( 3.0f,  1.0f),
    };
    RainVSOut out;
    out.position = float4(pos[vid], 0.0f, 1.0f);
    out.uv = pos[vid] * 0.5f + 0.5f;
    return out;
}

// MARK: - Fragment: liquid-glass overlay (ported from JS mobile Liquid Glass shader)

fragment float4 rain_fragment(
    RainVSOut              in       [[stage_in]],
    texture2d<float>       waterMap [[texture(0)]],
    constant RainUniforms& u        [[buffer(0)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    // tc: y=0 at top of screen, matching the water map and simulation
    const float2 tc  = float2(in.uv.x, 1.0f - in.uv.y);
    const float4 cur = waterMap.sample(s, tc);

    const float d = cur.b;
    const float x = cur.g;
    const float y = cur.r;
    const float a = clamp(cur.a * u.alphaMultiply - u.alphaSubtract, 0.0f, 1.0f);

    if (a < 0.01f) {
        discard_fragment();
        return float4(0.0f);
    }

    // Reconstruct sphere normal
    const float2 ref = (float2(x, y) - 0.5f) * 2.0f;
    const float3 N   = normalize(float3(-ref, max(d, 0.001f)));

    // Lighting
    const float3 L    = normalize(float3(0.25f, 0.72f, 1.0f));
    const float3 H    = normalize(L + float3(0.0f, 0.0f, 1.0f));
    const float  diff  = max(dot(N, L), 0.0f);
    const float  spec1 = pow(max(dot(N, H), 0.0f), 92.0f);
    const float  spec2 = pow(max(dot(N, H), 0.0f), 14.0f) * 0.18f;

    // Thin-film iridescent rim
    const float nz = N.z;
    const float3 iri = float3(
        pow(1.0f - max(nz - 0.08f, 0.0f), 2.6f) * 0.82f,
        pow(1.0f - max(nz - 0.04f, 0.0f), 2.3f) * 0.76f,
        pow(1.0f - nz,                     2.0f) * 0.88f
    );

    const float  frost  = d * 0.12f;
    const float  shadow = 1.0f - smoothstep(-0.9f, 0.1f, N.y) * 0.35f;
    const float3 base   = float3(0.86f, 0.93f, 1.00f);
    float3 col = base * (0.04f + diff * 0.22f * shadow + frost)
               + iri
               + float3(1.00f, 0.98f, 0.96f) * (spec1 + spec2);

    // Soft drop shadow (sample slightly below in screen space)
    const float2 shadowTc = tc + float2(0.0f, d * 6.0f / u.waterMapHeight);
    const float  borderA  = clamp(
        waterMap.sample(s, shadowTc).a * u.alphaMultiply - (u.alphaSubtract + 0.5f),
        0.0f, 1.0f) * 0.15f;
    col *= (1.0f - borderA);

    const float alpha = clamp(a * (0.7f + iri.r * 0.5f + spec1 * 0.5f), 0.0f, 0.92f) * u.intensity;
    return float4(col * u.brightness, alpha);
}

// MARK: - 3D World Rain

struct RainWorldVOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex RainWorldVOut rain_world_vertex(
    uint                    vid       [[vertex_id]],
    device const Rain3DParticleGPU* particles [[buffer(0)]],
    constant RainWorldUniforms&     u         [[buffer(1)]]
) {
    uint particleIdx = vid / 6;
    uint vertexIdx   = vid % 6;
    const device Rain3DParticleGPU& p = particles[particleIdx];

    // Procedural Fall Logic
    float phase = p.spawnXZ_phase_speed.y;
    float speed = p.spawnXZ_phase_speed.w;
    float t = fract(u.time * speed + phase); // [0, 1] fall progress

    // World Space Fall Segment
    float spawnY = 16.0;
    float groundY = 0.0;
    float worldY = mix(spawnY, groundY, t);
    
    // Wrap rain around camera position so it follows the user
    float range = 22.0; 
    float worldX = fmod(p.spawnXZ_phase_speed.x - u.cameraPos.x + range, range * 2.0f);
    if (worldX < 0) worldX += range * 2.0f;
    worldX = worldX - range + u.cameraPos.x;
    
    float worldZ = fmod(p.spawnXZ_phase_speed.z - u.cameraPos.z + range, range * 2.0f);
    if (worldZ < 0) worldZ += range * 2.0f;
    worldZ = worldZ - range + u.cameraPos.z;
    
    // Add wind drift
    worldX += u.wind.x * t * 4.0;
    worldZ += u.wind.y * t * 4.0;
    
    float3 headPos = float3(worldX, worldY, worldZ);
    float3 fallDir = normalize(float3(u.wind.x * 0.3, -1.0, u.wind.y * 0.3));
    
    // Quad creation
    float length = 0.4 + speed * 0.2;
    float width = 0.015;
    
    float3 right = normalize(cross(fallDir, float3(0, 0, 1)));
    if (abs(dot(fallDir, float3(0, 0, 1))) > 0.9f) {
        right = normalize(cross(fallDir, float3(1, 0, 0)));
    }

    float2 uvs[6] = {
        float2(0, 0), float2(1, 0), float2(1, 1),
        float2(0, 0), float2(1, 1), float2(0, 1)
    };
    float2 uv = uvs[vertexIdx];

    float3 vpos = headPos + (uv.x - 0.5f) * right * width + (uv.y - 1.0f) * fallDir * length;

    // Fading
    float groundFade = smoothstep(groundY, groundY + 1.5, worldY);
    float spawnFade  = smoothstep(0.0, 0.1, t) * smoothstep(1.0, 0.9, t);
    
    RainWorldVOut out;
    out.position = u.viewProjection * float4(vpos, 1.0f);
    out.uv = uv;
    out.color = p.color;
    out.color.a *= uv.y * groundFade * spawnFade * u.intensity;
    return out;
}

fragment float4 rain_world_fragment(RainWorldVOut in [[stage_in]]) {
    // Simple glowing streak
    float distToCenter = abs(in.uv.x - 0.5f) * 2.0f;
    float glow = exp(-distToCenter * 4.0f);
    return float4(in.color.rgb, in.color.a * glow);
}

// MARK: - 3D Ground Ripples

// Ripple logic removed
