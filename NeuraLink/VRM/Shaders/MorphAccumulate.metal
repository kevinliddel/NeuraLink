#include <metal_stdlib>
using namespace metal;

// Active morph structure matching Swift side
struct ActiveMorph {
    uint index;
    float weight;
};

// Compute kernel for morph position accumulation using SoA layout
kernel void morph_accumulate_positions(
    device const float3* basePos [[buffer(0)]],         // Base vertex positions
    device const float3* deltaPos [[buffer(1)]],        // SoA flattened morph deltas [T][V]
    device const ActiveMorph* activeSet [[buffer(2)]],  // Active morphs with weights
    constant uint& vertexCount [[buffer(3)]],           // Total vertex count
    constant uint& morphCount [[buffer(4)]],            // Total morph targets (for addressing)
    constant uint& activeCount [[buffer(5)]],           // Number of active morphs
    device float3* outPos [[buffer(6)]],                // Output morphed positions
    uint vid [[thread_position_in_grid]]
) {
    if (vid >= vertexCount) return;

    // Start with base position
    float3 pos = basePos[vid];

    // Accumulate active morph deltas
    for (uint k = 0; k < activeCount; ++k) {
        uint morphIdx = activeSet[k].index;
        float weight = activeSet[k].weight;

        // SoA indexing: morph M vertex V at index M*vertexCount + V
        uint deltaIdx = morphIdx * vertexCount + vid;
        pos += deltaPos[deltaIdx] * weight;
    }

    // Write morphed position
    outPos[vid] = pos;
}

// Compute kernel for morph normal accumulation (Phase B)
kernel void morph_accumulate_normals(
    device const float3* baseNrm [[buffer(0)]],         // Base vertex normals
    device const float3* deltaNrm [[buffer(1)]],        // SoA flattened normal deltas [T][V]
    device const ActiveMorph* activeSet [[buffer(2)]],  // Active morphs with weights
    constant uint& vertexCount [[buffer(3)]],           // Total vertex count
    constant uint& morphCount [[buffer(4)]],            // Total morph targets
    constant uint& activeCount [[buffer(5)]],           // Number of active morphs
    device float3* outNrm [[buffer(6)]],                // Output morphed normals
    uint vid [[thread_position_in_grid]]
) {
    if (vid >= vertexCount) return;

    // Start with base normal
    float3 nrm = baseNrm[vid];

    // Accumulate active morph deltas
    for (uint k = 0; k < activeCount; ++k) {
        uint morphIdx = activeSet[k].index;
        float weight = activeSet[k].weight;

        // SoA indexing
        uint deltaIdx = morphIdx * vertexCount + vid;
        nrm += deltaNrm[deltaIdx] * weight;
    }

    // Normalize and write morphed normal
    outNrm[vid] = normalize(nrm);
}

// Combined kernel for both positions and normals (more efficient)
kernel void morph_accumulate_combined(
    device const float3* basePos [[buffer(0)]],
    device const float3* baseNrm [[buffer(1)]],
    device const float3* deltaPos [[buffer(2)]],        // SoA position deltas
    device const float3* deltaNrm [[buffer(3)]],        // SoA normal deltas
    device const ActiveMorph* activeSet [[buffer(4)]],
    constant uint& vertexCount [[buffer(5)]],
    constant uint& morphCount [[buffer(6)]],
    constant uint& activeCount [[buffer(7)]],
    device float3* outPos [[buffer(8)]],
    device float3* outNrm [[buffer(9)]],
    uint vid [[thread_position_in_grid]]
) {
    if (vid >= vertexCount) return;

    float3 pos = basePos[vid];
    float3 nrm = baseNrm ? baseNrm[vid] : float3(0, 1, 0);

    // Single loop for both attributes
    for (uint k = 0; k < activeCount; ++k) {
        uint morphIdx = activeSet[k].index;
        float weight = activeSet[k].weight;
        uint deltaIdx = morphIdx * vertexCount + vid;

        pos += deltaPos[deltaIdx] * weight;
        if (deltaNrm) {
            nrm += deltaNrm[deltaIdx] * weight;
        }
    }

    outPos[vid] = pos;
    if (outNrm) {
        outNrm[vid] = normalize(nrm);
    }
}

// Debug kernel - copy base to output (for K=0 case)
kernel void morph_copy_base(
    device const float3* basePos [[buffer(0)]],
    device float3* outPos [[buffer(1)]],
    uint vid [[thread_position_in_grid]]
) {
    outPos[vid] = basePos[vid];
}