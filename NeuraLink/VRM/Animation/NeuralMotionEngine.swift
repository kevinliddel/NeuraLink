//
//  NeuralMotionEngine.swift
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

import Foundation
import simd

public final class NeuralMotionEngine: VRMAnimationDriver {
    
    private let retargeter = VRMHumanoidRetargeter()
    private var handle: OpaquePointer?
    private var baseHipsHeight: Float = 0
    
    /// The current intensity of the motion (0.0 = still, 1.0 = highly active).
    public var activityLevel: Float = 0.5
    
    /// Target emotion that influences the generative motion.
    public var currentEmotion: String = "neutral"
    
    public init() {
        handle = vrm_motion_create()
    }
    
    deinit {
        if let handle = handle {
            vrm_motion_free(handle)
        }
    }
    
    public func update(deltaTime: Float, model: VRMModel) {
        guard let handle = handle else { return }
        
        // Capture base height from the T-pose/Model data if not yet set
        if baseHipsHeight == 0, let hipsNodeIndex = model.humanoid?.getBoneNode(.hips) {
            baseHipsHeight = model.nodes[hipsNodeIndex].translation.y
        }
        
        // 1. Update C++ simulation
        vrm_motion_set_target(handle, currentEmotion, activityLevel)
        vrm_motion_update(handle, deltaTime)
        
        // 2. Fetch results
        let count = Int(vrm_motion_get_bone_count(handle))
        guard count > 0 else { return }
        
        var buffer = [VRMBoneTransform](repeating: VRMBoneTransform(), count: count)
        vrm_motion_get_bones(handle, &buffer, Int32(count))
        
        // 3. Convert to Pose
        var pose = VRMHumanoidRetargeter.HumanoidMotionPose()
        for transform in buffer {
            let name = String(cString: transform.bone_name)
            pose.boneRotations[name] = simd_quatf(vector: [transform.rot_x, transform.rot_y, transform.rot_z, transform.rot_w])
            
            // Root translation: Add base height to the generative offset
            if name == "hips" {
                pose.rootTranslation = [transform.pos_x, transform.pos_y + baseHipsHeight, transform.pos_z]
            }
        }
        
        // 4. Apply to model
        retargeter.apply(pose: pose, to: model)
    }
    
    /// Loads animation clips into the generative database
    public func load(clips: [AnimationClip]) {
        guard let handle = handle else { return }
        
        vrm_motion_db_clear(handle)
        
        for clip in clips {
            let duration = clip.duration
            let sampleRate: Float = 30.0 // 30 FPS for database sampling
            var time: Float = 0
            
            while time < duration {
                // Sample pose from clip
                let pose = clip.sample(at: time)
                
                // Feed to C++
                vrm_motion_db_begin_pose(handle, pose.rootTranslation.x, pose.rootTranslation.y, pose.rootTranslation.z)
                for (bone, rotation) in pose.boneRotations {
                    vrm_motion_db_add_bone(handle, bone, rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w)
                }
                vrm_motion_db_end_pose(handle)
                
                time += 1.0 / sampleRate
            }
        }
        
        print("[NeuralMotionEngine] Digested \(clips.count) clips into generative manifold.")
    }
}
