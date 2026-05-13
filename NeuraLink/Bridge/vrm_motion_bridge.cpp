//
//  vrm_motion_bridge.cpp
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

#include "vrm_motion_bridge.h"
#include "../VRM/Animation/Core/vrm_motion_core.hpp"
#include <string>
#include <vector>
#include <cstdint>

using namespace NeuraLink;

struct VRMMotionEngineHandle {
    MotionMatchingEngine engine;
    std::vector<std::string> bone_name_strings; // To keep C-strings valid
    HumanoidPose staging_pose; // Temporary pose being built
};

VRMMotionEngineHandle* vrm_motion_create(void) {
    return new VRMMotionEngineHandle();
}

void vrm_motion_free(VRMMotionEngineHandle* handle) {
    delete handle;
}

void vrm_motion_update(VRMMotionEngineHandle* handle, float dt) {
    if (handle) handle->engine.update(dt);
}

void vrm_motion_set_target(VRMMotionEngineHandle* handle, const char* emotion, float activity) {
    if (handle && emotion) {
        handle->engine.setTarget(std::string(emotion), activity);
    }
}

int32_t vrm_motion_get_bone_count(VRMMotionEngineHandle* handle) {
    if (!handle) return 0;
    return static_cast<int32_t>(handle->engine.getCurrentPose().bones.size());
}

void vrm_motion_get_bones(VRMMotionEngineHandle* handle, VRMBoneTransform* buffer, int32_t buffer_size) {
    if (!handle || !buffer) return;
    
    auto pose = handle->engine.getCurrentPose();
    int32_t count = 0;
    
    // Clear old string cache
    handle->bone_name_strings.clear();
    
    for (auto const& [name, transform] : pose.bones) {
        if (count >= buffer_size) break;
        
        handle->bone_name_strings.push_back(name);
        
        buffer[count].bone_name = handle->bone_name_strings.back().c_str();
        buffer[count].rot_x = transform.rotation.x;
        buffer[count].rot_y = transform.rotation.y;
        buffer[count].rot_z = transform.rotation.z;
        buffer[count].rot_w = transform.rotation.w;
        buffer[count].pos_x = transform.translation.x;
        buffer[count].pos_y = transform.translation.y;
        buffer[count].pos_z = transform.translation.z;
        
        count++;
    }
}

void vrm_motion_db_clear(VRMMotionEngineHandle* handle) {
    if (handle) handle->engine.clearDatabase();
}

void vrm_motion_db_begin_pose(VRMMotionEngineHandle* handle, float root_x, float root_y, float root_z) {
    if (!handle) return;
    handle->staging_pose = HumanoidPose();
    handle->staging_pose.rootTranslation = {root_x, root_y, root_z};
}

void vrm_motion_db_add_bone(VRMMotionEngineHandle* handle, const char* name, float rot_x, float rot_y, float rot_z, float rot_w) {
    if (!handle || !name) return;
    BoneTransform t;
    t.rotation = {rot_x, rot_y, rot_z, rot_w};
    t.translation = {0, 0, 0};
    handle->staging_pose.bones[std::string(name)] = t;
}

void vrm_motion_db_end_pose(VRMMotionEngineHandle* handle) {
    if (handle) handle->engine.addPoseToDatabase(handle->staging_pose);
}

bool vrm_motion_db_load_binary(VRMMotionEngineHandle* handle, const uint8_t* data, int32_t size) {
    if (!handle || !data || size <= 0) return false;
    return handle->engine.loadDatabaseFromBinary(data, static_cast<size_t>(size));
}
