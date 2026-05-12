#import "vrm_physics_bridge.h"
#import "../VRM/Physics/Core/vrm_physics_core.hpp"

struct VRMPhysicsHandle {
    VRM::Physics::Solver solver;
};

extern "C" {

VRMPhysicsHandle* vrm_physics_create(void) {
    return new VRMPhysicsHandle();
}

void vrm_physics_destroy(VRMPhysicsHandle* handle) {
    delete handle;
}

void vrm_physics_add_bone(VRMPhysicsHandle* handle, 
                          simd_float3 currentTail, 
                          simd_float3 prevTail, 
                          simd_float3 boneAxis, 
                          float boneLength,
                          float hitRadius,
                          float stiffness,
                          float gravityPower,
                          simd_float3 gravityDir,
                          float dragForce) {
    if (!handle) return;
    
    VRM::Physics::BoneState bone;
    bone.currentTail = currentTail;
    bone.prevTail = prevTail;
    bone.boneAxis = boneAxis;
    bone.boneLength = boneLength;
    
    VRM::Physics::JointParams params;
    params.hitRadius = hitRadius;
    params.stiffness = stiffness;
    params.gravityPower = gravityPower;
    params.gravityDir = gravityDir;
    params.dragForce = dragForce;
    
    handle->solver.addBone(bone, params);
}

void vrm_physics_set_limit_angle(VRMPhysicsHandle* handle, uint32_t boneIndex, float angleDegrees) {
    if (handle) {
        handle->solver.setLimitAngle(boneIndex, angleDegrees);
    }
}

void vrm_physics_add_chain_vrm0(VRMPhysicsHandle* handle, 
                                uint32_t rootNodeIndex, 
                                const uint32_t* colliderGroupIndices,
                                uint32_t colliderGroupCount,
                                VRMGetChildrenFunc getChildren, 
                                void* context) {
    if (!handle) return;
    
    std::vector<uint32_t> groups(colliderGroupIndices, colliderGroupIndices + colliderGroupCount);
    
    auto wrapper = [](uint32_t nodeIndex, void* ctx) -> std::vector<uint32_t> {
        auto* data = static_cast<std::pair<VRMGetChildrenFunc, void*>*>(ctx);
        uint32_array children = data->first(nodeIndex, data->second);
        return std::vector<uint32_t>(children.indices, children.indices + children.count);
    };
    
    std::pair<VRMGetChildrenFunc, void*> bridgeContext = {getChildren, context};
    handle->solver.addChainFromVRM0Root(rootNodeIndex, groups, wrapper, &bridgeContext);
}

void vrm_physics_update(VRMPhysicsHandle* handle, float deltaTime) {
    if (handle) {
        handle->solver.update(deltaTime);
    }
}

// Note: In a real app, we would read back all positions at once for performance.
// For this bridge example, we provide a single getter.
void vrm_physics_get_bone_position(VRMPhysicsHandle* handle, uint32_t boneIndex, simd_float3* outPosition) {
    // This requires exposing the m_bones in Solver or adding a getter.
    // For now, this is a placeholder to show the API.
}

}
