//
//  VRMHumanoidRetargeter.swift
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

import Foundation
import simd

/// VRMHumanoidRetargeter provides the bridge between standard humanoid motion data 
/// (e.g. from generative models, MoCap, or BVH) and the VRM bone hierarchy.
public final class VRMHumanoidRetargeter {
    
    /// A standardized humanoid pose representation, independent of any specific model.
    public struct HumanoidMotionPose {
        /// Rotations for each bone. The keys should match standard humanoid names.
        public var boneRotations: [String: simd_quatf] = [:]
        
        /// Root translation (usually for the hips).
        public var rootTranslation: SIMD3<Float> = [0, 0, 0]
        
        public init() {}
    }
    
    /// Mapping from standard humanoid bone names (e.g. Mixamo, SMPL) to VRMHumanoidBone.
    public static let standardMapping: [String: VRMHumanoidBone] = [
        "hips": .hips,
        "spine": .spine,
        "chest": .chest,
        "upperChest": .upperChest,
        "neck": .neck,
        "head": .head,
        
        "leftUpperArm": .leftUpperArm,
        "leftLowerArm": .leftLowerArm,
        "leftHand": .leftHand,
        "leftShoulder": .leftShoulder,
        
        "rightUpperArm": .rightUpperArm,
        "rightLowerArm": .rightLowerArm,
        "rightHand": .rightHand,
        "rightShoulder": .rightShoulder,
        
        "leftUpperLeg": .leftUpperLeg,
        "leftLowerLeg": .leftLowerLeg,
        "leftFoot": .leftFoot,
        "leftToes": .leftToes,
        
        "rightUpperLeg": .rightUpperLeg,
        "rightLowerLeg": .rightLowerLeg,
        "rightFoot": .rightFoot,
        "rightToes": .rightToes
    ]
    
    public init() {}
    
    /// Applies a standard pose to a VRM model.
    /// IMPORTANT: The rotations in `pose` must already be in model-local bone space.
    /// When poses come from AnimationClip.sample(), the VRMA sampler has already applied
    /// convertRotationForVRM0 and the modelRest*delta retargeting — do NOT re-convert here.
    public func apply(pose: HumanoidMotionPose, to model: VRMModel) {
        model.withLock {
            // 1. Apply root translation to Hips
            if let hipsIndex = model.humanoid?.getBoneNode(.hips) {
                // Root translation from clip.sample() is already in model space
                // (convertTranslationForVRM0 is applied inside the VRMA sampler).
                model.nodes[hipsIndex].translation = pose.rootTranslation
                model.nodes[hipsIndex].updateLocalMatrix()
            }

            // 2. Apply bone rotations — NO coordinate conversion needed.
            // Rotations sampled from AnimationClip are already fully retargeted
            // for the specific model (VRM 0.x or 1.x) by the VRMA loader.
            var appliedCount = 0
            for (name, rotation) in pose.boneRotations {
                let bone: VRMHumanoidBone?
                if let b = VRMHumanoidBone(rawValue: name) {
                    bone = b
                } else if let b = Self.standardMapping[name] {
                    bone = b
                } else {
                    bone = nil
                }

                guard let targetBone = bone,
                      let nodeIndex = model.humanoid?.getBoneNode(targetBone),
                      nodeIndex < model.nodes.count else {
                    continue
                }

                model.nodes[nodeIndex].rotation = rotation
                model.nodes[nodeIndex].updateLocalMatrix()
                appliedCount += 1
            }

            // 3. Propagate transforms
            model.updateNodeTransforms()

            // Periodic log so we can confirm bones are being set and how many
            if arc4random_uniform(120) == 0 {
                vrmLog("[Retargeter] Applied \(appliedCount)/\(pose.boneRotations.count) bones. VRM0=\(model.isVRM0). HipsT=\(pose.rootTranslation)")
            }
        }
    }
    
    /// Helper to create a pose from a dictionary of rotations.
    public func createPose(rotations: [String: simd_quatf], translation: SIMD3<Float> = .zero) -> HumanoidMotionPose {
        var pose = HumanoidMotionPose()
        pose.boneRotations = rotations
        pose.rootTranslation = translation
        return pose
    }
}
