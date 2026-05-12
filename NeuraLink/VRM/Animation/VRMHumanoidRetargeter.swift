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
                model.nodes[hipsIndex].translation = pose.rootTranslation
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
                
                if model.isVRM0 {
                    // VRM 0.0 Left-Handed conversion
                    // glTF (Right-handed) to Unity (Left-handed) conversion for rotations:
                    // Flip Y and Z components or X and W depending on coordinate system conventions.
                    // For VRM 0.0, we typically flip X and W or use a specific mapping.
                    // The user mentioned "reversed" bones, so let's ensure the handedness is corrected.
                    let corrected = simd_quatf(ix: -rotation.vector.x, iy: rotation.vector.y, iz: rotation.vector.z, r: -rotation.vector.w)
                    node.rotation = corrected
                } else {
                    // VRM 1.0 Rest Rotation Conversion
                    // Formula from spec: B.LocalRotation = L_rest * W_rest^-1 * NormalizedLocalRotation * W_rest
                    let L_rest = node.initialRotation
                    let W_rest = model.getInitialWorldRotation(for: nodeIndex)
                    
                    let invW_rest = W_rest.inverse
                    let normalizedRotation = rotation
                    
                    // B.LocalRotation = L_rest * (invW_rest * normalizedRotation * W_rest)
                    let targetRotation = L_rest * (invW_rest * normalizedRotation * W_rest)
                    node.rotation = targetRotation
                }
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
