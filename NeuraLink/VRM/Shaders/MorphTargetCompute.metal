#include <metal_stdlib>
using namespace metal;

// Compute shader for GPU-accelerated morph target blending
kernel void morphTargetCompute(
    device float3* basePositions [[buffer(0)]],          // Base vertex positions
    device float3* morphedPositions [[buffer(1)]],       // Output morphed positions
    constant float* morphWeights [[buffer(2)]],          // Morph target weights
    device float3* morphDelta0 [[buffer(3)]],           // Morph target 0 position deltas
    device float3* morphDelta1 [[buffer(4)]],           // Morph target 1 position deltas
    device float3* morphDelta2 [[buffer(5)]],           // Morph target 2 position deltas
    device float3* morphDelta3 [[buffer(6)]],           // Morph target 3 position deltas
    device float3* morphDelta4 [[buffer(7)]],           // Morph target 4 position deltas
    device float3* morphDelta5 [[buffer(8)]],           // Morph target 5 position deltas
    device float3* morphDelta6 [[buffer(9)]],           // Morph target 6 position deltas
    device float3* morphDelta7 [[buffer(10)]],          // Morph target 7 position deltas
    constant uint& morphTargetCount [[buffer(11)]],      // Number of active morph targets
    uint index [[thread_position_in_grid]]
) {
    // Start with base position
    float3 result = basePositions[index];

    // Apply morph targets based on count
    if (morphTargetCount > 0 && morphDelta0) {
        result += morphDelta0[index] * morphWeights[0];
    }
    if (morphTargetCount > 1 && morphDelta1) {
        result += morphDelta1[index] * morphWeights[1];
    }
    if (morphTargetCount > 2 && morphDelta2) {
        result += morphDelta2[index] * morphWeights[2];
    }
    if (morphTargetCount > 3 && morphDelta3) {
        result += morphDelta3[index] * morphWeights[3];
    }
    if (morphTargetCount > 4 && morphDelta4) {
        result += morphDelta4[index] * morphWeights[4];
    }
    if (morphTargetCount > 5 && morphDelta5) {
        result += morphDelta5[index] * morphWeights[5];
    }
    if (morphTargetCount > 6 && morphDelta6) {
        result += morphDelta6[index] * morphWeights[6];
    }
    if (morphTargetCount > 7 && morphDelta7) {
        result += morphDelta7[index] * morphWeights[7];
    }

    // Write morphed position
    morphedPositions[index] = result;
}

// Compute shader for normal morphing
kernel void morphNormalCompute(
    device float3* baseNormals [[buffer(0)]],           // Base vertex normals
    device float3* morphedNormals [[buffer(1)]],        // Output morphed normals
    constant float* morphWeights [[buffer(2)]],         // Morph target weights
    device float3* morphDelta0 [[buffer(3)]],          // Morph target 0 normal deltas
    device float3* morphDelta1 [[buffer(4)]],          // Morph target 1 normal deltas
    device float3* morphDelta2 [[buffer(5)]],          // Morph target 2 normal deltas
    device float3* morphDelta3 [[buffer(6)]],          // Morph target 3 normal deltas
    device float3* morphDelta4 [[buffer(7)]],          // Morph target 4 normal deltas
    device float3* morphDelta5 [[buffer(8)]],          // Morph target 5 normal deltas
    device float3* morphDelta6 [[buffer(9)]],          // Morph target 6 normal deltas
    device float3* morphDelta7 [[buffer(10)]],         // Morph target 7 normal deltas
    constant uint& morphTargetCount [[buffer(11)]],     // Number of active morph targets
    uint index [[thread_position_in_grid]]
) {
    // Start with base normal
    float3 result = baseNormals[index];

    // Apply morph targets based on count
    if (morphTargetCount > 0 && morphDelta0) {
        result += morphDelta0[index] * morphWeights[0];
    }
    if (morphTargetCount > 1 && morphDelta1) {
        result += morphDelta1[index] * morphWeights[1];
    }
    if (morphTargetCount > 2 && morphDelta2) {
        result += morphDelta2[index] * morphWeights[2];
    }
    if (morphTargetCount > 3 && morphDelta3) {
        result += morphDelta3[index] * morphWeights[3];
    }
    if (morphTargetCount > 4 && morphDelta4) {
        result += morphDelta4[index] * morphWeights[4];
    }
    if (morphTargetCount > 5 && morphDelta5) {
        result += morphDelta5[index] * morphWeights[5];
    }
    if (morphTargetCount > 6 && morphDelta6) {
        result += morphDelta6[index] * morphWeights[6];
    }
    if (morphTargetCount > 7 && morphDelta7) {
        result += morphDelta7[index] * morphWeights[7];
    }

    // Normalize and write morphed normal
    morphedNormals[index] = normalize(result);
}

// Advanced compute shader for morphing with multiple attributes
struct MorphVertex {
    float3 position;
    float3 normal;
    float2 texCoord;
    float4 color;
};

kernel void morphVertexCompute(
    device MorphVertex* baseVertices [[buffer(0)]],      // Base vertices
    device MorphVertex* morphedVertices [[buffer(1)]],   // Output morphed vertices
    constant float* morphWeights [[buffer(2)]],          // Morph target weights
    device MorphVertex* morphTargets [[buffer(3)]],      // All morph target deltas
    constant uint& morphTargetCount [[buffer(4)]],       // Number of active morph targets
    constant uint& vertexCount [[buffer(5)]],            // Total vertex count
    uint index [[thread_position_in_grid]]
) {
    if (index >= vertexCount) return;

    // Start with base vertex
    MorphVertex result = baseVertices[index];

    // Apply all morph targets
    for (uint i = 0; i < morphTargetCount; ++i) {
        uint morphIndex = i * vertexCount + index;
        float weight = morphWeights[i];

        result.position += morphTargets[morphIndex].position * weight;
        result.normal += morphTargets[morphIndex].normal * weight;
        // Optionally morph other attributes
    }

    // Normalize normal
    result.normal = normalize(result.normal);

    // Write morphed vertex
    morphedVertices[index] = result;
}