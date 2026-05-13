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
    private var lastModelID: ObjectIdentifier?
    private var hasDatabase: Bool = false
    private var filteredRotations: [String: simd_quatf] = [:]
    private var filteredRootTranslation: SIMD3<Float> = .zero
    private var hasFilterState: Bool = false
    /// Whether the loaded dataset quaternions are glTF-right-handed and need VRM0 conversion.
    /// Your current Three.js-exported database is already in the correct space for both VRM0/VRM1,
    /// so keep this off unless you regenerate a dataset that is known to be glTF-only.
    private var requiresVRM0Conversion: Bool = false

    /// Set by VRMMetalState before calling `load(clips:)` so we can choose the right binary DB.
    public var isCurrentModelVRM0: Bool = false
    
    /// The current intensity of the motion (0.0 = still, 1.0 = highly active).
    public var activityLevel: Float = 0.5

    /// Smoothing time constant (seconds) for generative pose output.
    /// Smaller = snappier, larger = smoother.
    public var smoothingTau: Float = 0.09

    /// Inserts a short neutral hold between digested clips so the motion matcher
    /// doesn't hard-cut from one clip's ending into the next clip's first frame.
    public var interClipHoldSeconds: Float = 0.35
    
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
        guard hasDatabase else { return }

        let modelID = ObjectIdentifier(model)
        if lastModelID != modelID {
            lastModelID = modelID
            baseHipsHeight = 0
            filteredRotations.removeAll()
            filteredRootTranslation = .zero
            hasFilterState = false
        }
        
        // Capture base height from the T-pose/Model data if not yet set
        if baseHipsHeight == 0, let hipsNodeIndex = model.humanoid?.getBoneNode(.hips) {
            baseHipsHeight = model.nodes[hipsNodeIndex].translation.y
        }
        
        // 1. Update C++ simulation
        vrm_motion_set_target(handle, currentEmotion, activityLevel)
        vrm_motion_update(handle, deltaTime)
        
        // Log periodically
        if arc4random_uniform(60) == 0 {
            vrmLog("[NeuralMotionEngine] Updating emotion: \(currentEmotion), activity: \(activityLevel)")
        }
        
        // 2. Fetch results
        let count = Int(vrm_motion_get_bone_count(handle))
        guard count > 0 else { return }
        
        var buffer = [VRMBoneTransform](repeating: VRMBoneTransform(), count: count)
        vrm_motion_get_bones(handle, &buffer, Int32(count))
        
        // 3. Convert to Pose
        var pose = VRMHumanoidRetargeter.HumanoidMotionPose()
        var targetRotations: [String: simd_quatf] = [:]
        var targetRootTranslation: SIMD3<Float> = .zero
        for transform in buffer {
            let name = String(cString: transform.bone_name)
            let q = simd_quatf(vector: [transform.rot_x, transform.rot_y, transform.rot_z, transform.rot_w])
            targetRotations[name] = q
            
            // Root translation: Add base height to the generative offset
            if name == "hips" {
                targetRootTranslation = [transform.pos_x, transform.pos_y + baseHipsHeight, transform.pos_z]
            }
        }

        // 3.5 Smooth output to avoid visible "pops" when the motion matcher switches states.
        // Use exponential smoothing: alpha = 1 - exp(-dt/tau)
        let tau = max(smoothingTau, 0.001)
        let alpha = 1 - exp(-deltaTime / tau)
        if !hasFilterState {
            filteredRotations = targetRotations
            filteredRootTranslation = targetRootTranslation
            hasFilterState = true
        } else {
            for (name, targetQ) in targetRotations {
                if let prevQ = filteredRotations[name] {
                    filteredRotations[name] = simd_slerp(prevQ, targetQ, alpha)
                } else {
                    filteredRotations[name] = targetQ
                }
            }
            filteredRootTranslation = filteredRootTranslation + (targetRootTranslation - filteredRootTranslation) * alpha
        }

        if model.isVRM0, requiresVRM0Conversion {
            for (k, v) in filteredRotations { filteredRotations[k] = convertRotationForVRM0(v) }
        }

        pose.boneRotations = filteredRotations
        pose.rootTranslation = filteredRootTranslation
        
        // 4. Apply to model
        retargeter.apply(pose: pose, to: model)
    }
    
    /// Loads animation clips into the generative database
    public func load(clips: [AnimationClip]) {
        guard let handle = handle else { return }

        // Prefer loading a prebuilt binary database from the app bundle.
        if let url = Self.findMotionDBURLInBundle(preferVRM0: isCurrentModelVRM0) {
            if let data = try? Data(contentsOf: url),
               vrm_motion_db_load_binary(handle, (data as NSData).bytes.assumingMemoryBound(to: UInt8.self), Int32(data.count)) {
                hasDatabase = true
                // If we explicitly ship a VRM0-adjusted DB, no runtime conversion needed.
                requiresVRM0Conversion = false
                vrmLog("[NeuralMotionEngine] Loaded binary motion DB: \(data.count) bytes (\(url.lastPathComponent)) VRM0=\(isCurrentModelVRM0)")
                return
            } else {
                vrmLog("[NeuralMotionEngine] ⚠️ Found motion_db.bin but failed to load: \(url.path)")
            }
        } else {
            vrmLog("[NeuralMotionEngine] motion_db.bin not found in bundle — falling back to VRMA digestion")
        }
        
        vrm_motion_db_clear(handle)
        hasDatabase = false
        requiresVRM0Conversion = false
        var totalFrames = 0

        let sampleRate: Float = 30.0 // 30 FPS for database sampling
        let neutralHoldClip = clips.first
        let holdFrames = max(0, Int(interClipHoldSeconds * sampleRate))
        
        for clip in clips {
            let duration = clip.duration
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
                totalFrames += 1
            }

            // Pad between clips with a neutral hold to reduce "rapid switching" feel.
            if holdFrames > 0, let neutralPose = neutralHoldClip?.sample(at: 0) {
                for _ in 0..<holdFrames {
                    vrm_motion_db_begin_pose(handle, neutralPose.rootTranslation.x, neutralPose.rootTranslation.y, neutralPose.rootTranslation.z)
                    for (bone, rotation) in neutralPose.boneRotations {
                        vrm_motion_db_add_bone(handle, bone, rotation.vector.x, rotation.vector.y, rotation.vector.z, rotation.vector.w)
                    }
                    vrm_motion_db_end_pose(handle)
                    totalFrames += 1
                }
            }
        }
        
        hasDatabase = totalFrames > 0
        vrmLog("[NeuralMotionEngine] Digested \(clips.count) clips into generative manifold. Total frames: \(totalFrames)")
    }

    private static func findMotionDBURLInBundle(preferVRM0: Bool) -> URL? {
        let candidates: [(String, String, String?)] = preferVRM0
            ? [("motion_db_vrm0", "bin", "Models"), ("motion_db_vrm0", "bin", nil), ("motion_db", "bin", "Models"), ("motion_db", "bin", nil)]
            : [("motion_db", "bin", "Models"), ("motion_db", "bin", nil)]
        for (name, ext, subdir) in candidates {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir) {
                return url
            }
        }
        // Common location: bundled under Models/
        // Last resort: brute-force search within the app bundle.
        if let resourcesURL = Bundle.main.resourceURL,
           let enumerator = FileManager.default.enumerator(at: resourcesURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if preferVRM0 && fileURL.lastPathComponent == "motion_db_vrm0.bin" {
                    return fileURL
                }
                if fileURL.lastPathComponent == "motion_db.bin" {
                    return fileURL
                }
            }
        }
        return nil
    }
}
