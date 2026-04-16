//
// VRMBuilder+Skeleton.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation

// MARK: - Skeleton Presets

public enum SkeletonPreset {
    case defaultHumanoid
    case tall
    case short
    case stocky

    func createSkeleton() -> SkeletonDefinition {
        switch self {
        case .defaultHumanoid:
            return SkeletonDefinition.defaultHumanoid()
        case .tall:
            return SkeletonDefinition.tall()
        case .short:
            return SkeletonDefinition.short()
        case .stocky:
            return SkeletonDefinition.stocky()
        }
    }
}

// MARK: - Skeleton Definition

public struct BoneData {
    let bone: VRMHumanoidBone
    let translation: [Float]
    let children: [Int]?
}

public struct SkeletonDefinition {
    var bones: [BoneData]

    /// Default humanoid skeleton (1.7m tall)
    static func defaultHumanoid() -> SkeletonDefinition {
        let bones: [BoneData] = [
            // 0: hips (root)
            BoneData(bone: .hips, translation: [0, 0.95, 0], children: [1, 8, 11]),
            // 1: spine
            BoneData(bone: .spine, translation: [0, 0.1, 0], children: [2]),
            // 2: chest
            BoneData(bone: .chest, translation: [0, 0.15, 0], children: [3]),
            // 3: upperChest
            BoneData(bone: .upperChest, translation: [0, 0.15, 0], children: [4, 5, 7]),
            // 4: neck
            BoneData(bone: .neck, translation: [0, 0.1, 0], children: [14]),
            // 5: leftShoulder
            BoneData(bone: .leftShoulder, translation: [0.05, 0.05, 0], children: [6]),
            // 6: leftUpperArm
            BoneData(bone: .leftUpperArm, translation: [0.15, 0, 0], children: [15]),
            // 7: rightShoulder
            BoneData(bone: .rightShoulder, translation: [-0.05, 0.05, 0], children: [16]),
            // 8: leftUpperLeg
            BoneData(bone: .leftUpperLeg, translation: [0.1, -0.05, 0], children: [9]),
            // 9: leftLowerLeg
            BoneData(bone: .leftLowerLeg, translation: [0, -0.45, 0], children: [10]),
            // 10: leftFoot
            BoneData(bone: .leftFoot, translation: [0, -0.45, 0], children: nil),
            // 11: rightUpperLeg
            BoneData(bone: .rightUpperLeg, translation: [-0.1, -0.05, 0], children: [12]),
            // 12: rightLowerLeg
            BoneData(bone: .rightLowerLeg, translation: [0, -0.45, 0], children: [13]),
            // 13: rightFoot
            BoneData(bone: .rightFoot, translation: [0, -0.45, 0], children: nil),
            // 14: head
            BoneData(bone: .head, translation: [0, 0.1, 0], children: nil),
            // 15: leftLowerArm
            BoneData(bone: .leftLowerArm, translation: [0.25, 0, 0], children: [17]),
            // 16: rightUpperArm
            BoneData(bone: .rightUpperArm, translation: [-0.15, 0, 0], children: [18]),
            // 17: leftHand
            BoneData(bone: .leftHand, translation: [0.25, 0, 0], children: nil),
            // 18: rightLowerArm
            BoneData(bone: .rightLowerArm, translation: [-0.25, 0, 0], children: [19]),
            // 19: rightHand
            BoneData(bone: .rightHand, translation: [-0.25, 0, 0], children: nil),
        ]

        return SkeletonDefinition(bones: bones)
    }

    /// Tall skeleton (2.0m)
    static func tall() -> SkeletonDefinition {
        var def = defaultHumanoid()
        // Scale all Y translations by 1.18
        def.bones = def.bones.map { bone in
            var newTranslation = bone.translation
            newTranslation[1] *= 1.18
            return BoneData(bone: bone.bone, translation: newTranslation, children: bone.children)
        }
        return def
    }

    /// Short skeleton (1.4m)
    static func short() -> SkeletonDefinition {
        var def = defaultHumanoid()
        // Scale all Y translations by 0.82
        def.bones = def.bones.map { bone in
            var newTranslation = bone.translation
            newTranslation[1] *= 0.82
            return BoneData(bone: bone.bone, translation: newTranslation, children: bone.children)
        }
        return def
    }

    /// Stocky skeleton (wider proportions)
    static func stocky() -> SkeletonDefinition {
        var def = defaultHumanoid()
        // Scale X translations by 1.2 for shoulders/hips
        def.bones = def.bones.map { bone in
            var newTranslation = bone.translation
            if bone.bone == .leftShoulder || bone.bone == .leftUpperLeg {
                newTranslation[0] *= 1.2
            } else if bone.bone == .rightShoulder || bone.bone == .rightUpperLeg {
                newTranslation[0] *= 1.2
            }
            return BoneData(bone: bone.bone, translation: newTranslation, children: bone.children)
        }
        return def
    }
}
