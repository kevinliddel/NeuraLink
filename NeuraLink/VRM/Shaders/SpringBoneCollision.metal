#include <metal_stdlib>
using namespace metal;

struct SphereCollider {
    float3 center;
    float radius;
    uint groupIndex;  // Index of collision group this collider belongs to
};

struct CapsuleCollider {
    float3 p0;
    float3 p1;
    float radius;
    uint groupIndex;  // Index of collision group this collider belongs to
};

struct PlaneCollider {
    float3 point;     // Point on the plane
    float3 normal;    // Plane normal (normalized)
    uint groupIndex;  // Index of collision group this collider belongs to
};

struct SpringBoneParams {
    float3 gravity;
    float dtSub;
    float windAmplitude;
    float windFrequency;
    float windPhase;
    float3 windDirection;
    uint substeps;
    uint numBones;
    uint numSpheres;
    uint numCapsules;
    uint numPlanes;
    uint settlingFrames;  // Frames remaining in settling period
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

// Sphere collision function with group filtering
float3 collideWithSphereFiltered(float3 position, float boneRadius, uint groupMask,
                                  constant SphereCollider* spheres, uint numSpheres) {
    float3 result = position;

    for (uint i = 0; i < numSpheres; i++) {
        SphereCollider sphere = spheres[i];

        // Skip if bone doesn't collide with this group
        if (!(groupMask & (1u << sphere.groupIndex))) continue;

        float3 toCenter = position - sphere.center;
        float distance = length(toCenter);
        float penetration = sphere.radius + boneRadius - distance;

        if (penetration > 0.0) {
            float3 normal = toCenter / max(distance, 1e-6);
            result += normal * penetration;
        }
    }

    return result;
}

// Capsule collision function with group filtering
float3 collideWithCapsuleFiltered(float3 position, float boneRadius, uint groupMask,
                                   constant CapsuleCollider* capsules, uint numCapsules) {
    float3 result = position;
    const float epsilon = 1e-6;

    for (uint i = 0; i < numCapsules; i++) {
        CapsuleCollider capsule = capsules[i];

        // Skip if bone doesn't collide with this group
        if (!(groupMask & (1u << capsule.groupIndex))) continue;

        // Find closest point on capsule segment
        float3 ab = capsule.p1 - capsule.p0;
        float ab_length_sq = dot(ab, ab);

        // Add epsilon check to prevent division by zero
        float t = (ab_length_sq > epsilon) ? dot(position - capsule.p0, ab) / ab_length_sq : 0.0;
        t = clamp(t, 0.0, 1.0);
        float3 closestPoint = capsule.p0 + t * ab;

        float3 toClosest = position - closestPoint;
        float distance = length(toClosest);
        float penetration = capsule.radius + boneRadius - distance;

        if (penetration > 0.0) {
            float3 normal = toClosest / max(distance, epsilon);
            result += normal * penetration;
        }
    }

    return result;
}

// Plane collision function with group filtering
float3 collideWithPlaneFiltered(float3 position, float boneRadius, uint groupMask,
                                 constant PlaneCollider* planes, uint numPlanes) {
    float3 result = position;

    for (uint i = 0; i < numPlanes; i++) {
        PlaneCollider plane = planes[i];

        // Skip if bone doesn't collide with this group
        if (!(groupMask & (1u << plane.groupIndex))) continue;

        // Distance from bone to plane (negative if below plane)
        float3 toPoint = position - plane.point;
        float distance = dot(toPoint, plane.normal) - boneRadius;

        if (distance < 0.0) {
            // Push bone out of plane
            result += plane.normal * (-distance);
        }
    }

    return result;
}

kernel void springBoneCollideSpheres(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SphereCollider* sphereColliders [[buffer(5)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numSpheres == 0) return;

    float boneRadius = boneParams[id].radius;
    uint groupMask = boneParams[id].colliderGroupMask;
    bonePosCurr[id] = collideWithSphereFiltered(bonePosCurr[id], boneRadius, groupMask,
                                                 sphereColliders, globalParams.numSpheres);
}

kernel void springBoneCollideCapsules(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant CapsuleCollider* capsuleColliders [[buffer(6)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numCapsules == 0) return;

    float boneRadius = boneParams[id].radius;
    uint groupMask = boneParams[id].colliderGroupMask;
    bonePosCurr[id] = collideWithCapsuleFiltered(bonePosCurr[id], boneRadius, groupMask,
                                                  capsuleColliders, globalParams.numCapsules);
}

kernel void springBoneCollidePlanes(
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant PlaneCollider* planeColliders [[buffer(7)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones || globalParams.numPlanes == 0) return;

    float boneRadius = boneParams[id].radius;
    uint groupMask = boneParams[id].colliderGroupMask;
    bonePosCurr[id] = collideWithPlaneFiltered(bonePosCurr[id], boneRadius, groupMask,
                                                planeColliders, globalParams.numPlanes);
}
