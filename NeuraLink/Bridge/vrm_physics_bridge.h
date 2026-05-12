#ifndef VRM_PHYSICS_BRIDGE_H
#define VRM_PHYSICS_BRIDGE_H

#include <stdint.h>
#include <simd/simd.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VRMPhysicsHandle VRMPhysicsHandle;

// MARK: - Lifecycle
VRMPhysicsHandle* vrm_physics_create(void);
void vrm_physics_destroy(VRMPhysicsHandle* handle);

// MARK: - Setup
void vrm_physics_add_bone(VRMPhysicsHandle* handle, 
                          simd_float3 currentTail, 
                          simd_float3 prevTail, 
                          simd_float3 boneAxis, 
                          float boneLength,
                          float hitRadius,
                          float stiffness,
                          float gravityPower,
                          simd_float3 gravityDir,
                          float dragForce);

void vrm_physics_set_limit_angle(VRMPhysicsHandle* handle, uint32_t boneIndex, float angleDegrees);

// VRM 0.x Support
typedef struct {
    uint32_t count;
    uint32_t* indices;
} uint32_array;

typedef uint32_array (*VRMGetChildrenFunc)(uint32_t nodeIndex, void* context);

void vrm_physics_add_chain_vrm0(VRMPhysicsHandle* handle, 
                                uint32_t rootNodeIndex, 
                                const uint32_t* colliderGroupIndices,
                                uint32_t colliderGroupCount,
                                VRMGetChildrenFunc getChildren, 
                                void* context);

// MARK: - Execution
void vrm_physics_update(VRMPhysicsHandle* handle, float deltaTime);

// MARK: - Data Readback
void vrm_physics_get_bone_position(VRMPhysicsHandle* handle, uint32_t boneIndex, simd_float3* outPosition);

#ifdef __cplusplus
}
#endif

#endif // VRM_PHYSICS_BRIDGE_H
