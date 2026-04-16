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

kernel void springBoneDistance(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant float* restLengths [[buffer(4)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    constant float3* bindDirections [[buffer(11)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones) return;

    uint parentIndex = boneParams[id].parentIndex;
    if (parentIndex == 0xFFFFFFFF) return; // Skip root bones

    float3 delta = bonePosCurr[id] - bonePosCurr[parentIndex];
    float currentLength = length(delta);
    float restLength = restLengths[id];

    const float epsilon = 1e-6;
    if (currentLength > epsilon && restLength > epsilon) {
        // HARD DISTANCE CONSTRAINT: Always project to exact rest length
        // Matches three-vrm behavior - no tolerance band that allows compression/stretch
        // This prevents the "tightening" issue where clothes compress to 95% and stick
        float3 direction = delta / currentLength;
        bonePosCurr[id] = bonePosCurr[parentIndex] + direction * restLength;
    } else if (restLength > epsilon && currentLength < epsilon) {
        // If bone fully collapsed to parent position, use bind direction to push out
        float3 bindDir = bindDirections[id];
        float bindLen = length(bindDir);
        float3 pushDir = (bindLen > 0.001) ? (bindDir / bindLen) : float3(0, -1, 0);
        bonePosCurr[id] = bonePosCurr[parentIndex] + pushDir * restLength;
    }
}