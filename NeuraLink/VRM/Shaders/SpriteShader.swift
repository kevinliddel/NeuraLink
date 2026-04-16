//
//  SpriteShader.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

/// Sprite batch rendering shader for cached character poses
/// Optimized for rendering multiple 2D sprite quads efficiently
public class SpriteShader {
    public static let shaderSource = """
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
        """
}

// MARK: - CPU-Side Structures

/// Sprite instance data (CPU-side)
public struct SpriteInstanceCPU {
    public var modelMatrix: simd_float4x4
    public var tintColor: SIMD4<Float>
    public var texOffset: SIMD2<Float>
    public var texScale: SIMD2<Float>

    public init(
        modelMatrix: simd_float4x4 = matrix_identity_float4x4,
        tintColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        texOffset: SIMD2<Float> = SIMD2<Float>(0, 0),
        texScale: SIMD2<Float> = SIMD2<Float>(1, 1)
    ) {
        self.modelMatrix = modelMatrix
        self.tintColor = tintColor
        self.texOffset = texOffset
        self.texScale = texScale
    }

    /// Create instance with position, rotation, and scale
    public static func makeInstance(
        position: SIMD3<Float>,
        rotation: Float = 0.0,
        scale: SIMD2<Float> = SIMD2<Float>(1, 1),
        tintColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    ) -> SpriteInstanceCPU {
        // Build transformation matrix
        let translationMatrix = matrix_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(position.x, position.y, position.z, 1)
        )

        let rotationMatrix = matrix_float4x4(
            SIMD4<Float>(cos(rotation), sin(rotation), 0, 0),
            SIMD4<Float>(-sin(rotation), cos(rotation), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let scaleMatrix = matrix_float4x4(
            SIMD4<Float>(scale.x, 0, 0, 0),
            SIMD4<Float>(0, scale.y, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )

        let modelMatrix = translationMatrix * rotationMatrix * scaleMatrix

        return SpriteInstanceCPU(
            modelMatrix: modelMatrix,
            tintColor: tintColor
        )
    }
}

/// Sprite uniforms (CPU-side)
public struct SpriteUniformsCPU {
    public var viewProjectionMatrix: simd_float4x4
    public var viewportSize: SIMD2<Float>
    public var _padding1: Float = 0
    public var _padding2: Float = 0

    public init(
        viewProjectionMatrix: simd_float4x4,
        viewportSize: SIMD2<Float>
    ) {
        self.viewProjectionMatrix = viewProjectionMatrix
        self.viewportSize = viewportSize
    }
}

// MARK: - Quad Mesh Generator

/// Generates a simple quad mesh for sprite rendering
public struct SpriteQuadMesh {
    /// Sprite vertex (position + texCoord)
    public struct Vertex {
        var position: SIMD2<Float>
        var texCoord: SIMD2<Float>
    }

    /// Create a quad mesh centered at origin
    /// - Parameter size: Quad size (default: 1x1, centered at origin)
    /// - Returns: Tuple of (vertices, indices)
    public static func createQuad(size: SIMD2<Float> = SIMD2<Float>(1, 1)) -> ([Vertex], [UInt16]) {
        let halfWidth = size.x * 0.5
        let halfHeight = size.y * 0.5

        // Vertices (counter-clockwise winding)
        let vertices: [Vertex] = [
            Vertex(position: SIMD2<Float>(-halfWidth, -halfHeight), texCoord: SIMD2<Float>(0, 1)),  // Bottom-left
            Vertex(position: SIMD2<Float>(halfWidth, -halfHeight), texCoord: SIMD2<Float>(1, 1)),  // Bottom-right
            Vertex(position: SIMD2<Float>(halfWidth, halfHeight), texCoord: SIMD2<Float>(1, 0)),  // Top-right
            Vertex(position: SIMD2<Float>(-halfWidth, halfHeight), texCoord: SIMD2<Float>(0, 0)),  // Top-left
        ]

        // Indices (two triangles)
        let indices: [UInt16] = [
            0, 1, 2,  // First triangle
            0, 2, 3,  // Second triangle
        ]

        return (vertices, indices)
    }

    /// Create Metal buffers for quad mesh
    public static func createBuffers(device: MTLDevice) -> (
        vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer
    )? {
        let (vertices, indices) = createQuad()

        guard
            let vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<Vertex>.stride,
                options: .storageModeShared
            )
        else {
            return nil
        }

        guard
            let indexBuffer = device.makeBuffer(
                bytes: indices,
                length: indices.count * MemoryLayout<UInt16>.stride,
                options: .storageModeShared
            )
        else {
            return nil
        }

        return (vertexBuffer, indexBuffer)
    }
}
