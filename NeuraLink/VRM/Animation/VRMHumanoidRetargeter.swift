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
    /// This handles name mapping and ensures the rig is updated correctly.
    public func apply(pose: HumanoidMotionPose, to model: VRMModel) {
        model.withLock {
            // 1. Apply root translation to Hips
            if let hipsIndex = model.humanoid?.getBoneNode(.hips) {
                var translation = pose.rootTranslation
                if model.isVRM0 {
                    translation = SIMD3<Float>(-translation.x, translation.y, -translation.z)
                }
                model.nodes[hipsIndex].translation = translation
                model.nodes[hipsIndex].updateLocalMatrix()
            }
            
            // 2. Apply bone rotations using the mapping
            for (name, rotation) in pose.boneRotations {
                // Try direct enum match first, then mapping
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
                
                let node = model.nodes[nodeIndex]
                
                // 1. Convert normalized animation rotation to model space
                let nRotation = rotation
                
                // 2. Apply the Rest Rotation Transformation Formula
                // Formula: B.LocalRotation = L_rest * (W_rest.inverse * N * W_rest)
                // This ensures the animation is applied relative to the bone's actual orientation in T-Pose/A-Pose.
                let L_rest = node.initialRotation
                var W_rest = model.getInitialWorldRotation(for: nodeIndex)
                
                if model.isVRM0 {
                    // VRM 0.0 faces -Z, but VRMA (nRotation) assumes +Z.
                    // We rotate W_rest by 180 degrees around Y to map the spaces.
                    let y180 = simd_quatf(angle: .pi, axis: [0, 1, 0])
                    W_rest = y180 * W_rest
                }
                
                let targetRotation = L_rest * (W_rest.inverse * nRotation * W_rest)
                node.rotation = targetRotation
                node.updateLocalMatrix()
            }
            
            // 3. Propagate transforms
            model.updateNodeTransforms()
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
