//
//  vrm_motion_bridge.h
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

#ifndef vrm_motion_bridge_h
#define vrm_motion_bridge_h

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

typedef struct VRMMotionEngineHandle VRMMotionEngineHandle;

// Lifecycle
VRMMotionEngineHandle* vrm_motion_create(void);
void vrm_motion_free(VRMMotionEngineHandle* handle);

// Controls
void vrm_motion_update(VRMMotionEngineHandle* handle, float dt);
void vrm_motion_set_target(VRMMotionEngineHandle* handle, const char* emotion, float activity);

// Output data
typedef struct {
    const char* bone_name;
    float rot_x, rot_y, rot_z, rot_w;
    float pos_x, pos_y, pos_z;
} VRMBoneTransform;

/// Gets the number of animated bones in the current pose
int32_t vrm_motion_get_bone_count(VRMMotionEngineHandle* handle);

/// Fills the provided buffer with bone transforms.
/// Buffer must be at least as large as the count returned by get_bone_count.
void vrm_motion_get_bones(VRMMotionEngineHandle* handle, VRMBoneTransform* buffer, int32_t buffer_size);

// Database Management
void vrm_motion_db_clear(VRMMotionEngineHandle* handle);
void vrm_motion_db_begin_pose(VRMMotionEngineHandle* handle, float root_x, float root_y, float root_z);
void vrm_motion_db_add_bone(VRMMotionEngineHandle* handle, const char* name, float rot_x, float rot_y, float rot_z, float rot_w);
void vrm_motion_db_end_pose(VRMMotionEngineHandle* handle);

#ifdef __cplusplus
}
#endif

#endif /* vrm_motion_bridge_h */
