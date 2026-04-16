#include <metal_stdlib>
using namespace metal;

struct SpringBoneParams {
    float3 gravity;       // offset 0
    float dtSub;          // offset 16 (after float3 padding)
    float windAmplitude;  // offset 20
    float windFrequency;  // offset 24
    float windPhase;      // offset 28
    float3 windDirection; // offset 32
    uint substeps;        // offset 48
    uint numBones;        // offset 52
    uint numSpheres;      // offset 56
    uint numCapsules;     // offset 60
    uint numPlanes;       // offset 64
    uint settlingFrames;  // offset 68 - frames remaining in settling period
};

struct BoneParams {
    float stiffness;
    float drag;
    float radius;
    uint parentIndex;
    float gravityPower;       // Multiplier for global gravity (0.0 = no gravity, 1.0 = full)
    uint colliderGroupMask;   // Bitmask of collision groups this bone collides with
    float3 gravityDir;        // Direction vector (normalized, typically [0, -1, 0])
};

// Updates root bone positions from animated transforms
// Buffer indices 8-10 are dedicated to kinematic kernel to avoid conflicts with colliders (5-7)
kernel void springBoneKinematic(
    device float3* bonePosCurr [[buffer(1)]],
    device float3* bonePosPrev [[buffer(0)]],
    constant float3* animatedRootPositions [[buffer(8)]], // Animated root positions
    constant uint* rootBoneIndices [[buffer(9)]],         // Indices of root bones
    constant uint& numRootBones [[buffer(10)]],           // Number of root bones
    uint id [[thread_position_in_grid]]
) {
    if (id >= numRootBones) return;

    uint boneIndex = rootBoneIndices[id];
    float3 animatedPos = animatedRootPositions[id];

    // Store previous position for velocity calculation
    float3 previousPos = bonePosCurr[boneIndex];

    // Update current position to match animated transform
    bonePosCurr[boneIndex] = animatedPos;

    // Update previous position to maintain velocity
    // This ensures smooth transitions when the animation moves
    bonePosPrev[boneIndex] = previousPos;
}