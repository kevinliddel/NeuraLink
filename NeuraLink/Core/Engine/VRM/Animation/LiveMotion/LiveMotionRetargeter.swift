//
//  LiveMotionRetargeter.swift
//  NeuraLink
//
//  ARDY's 27-joint skeleton (`cskel27`, identity rotation = T-pose, +Z
//  forward, +X to the model's left) onto a loaded VRM, with the same math
//  the VRMA loader applies to an identity-rest clip: the joint's local
//  rotation in the T-pose frame is conjugated into the model bone's
//  parent-rest basis and composed with the bone's rest rotation, flipped
//  first for VRM 0.x. Twenty humanoid bones are driven; Spine2 folds into
//  upperChest, hand ends, thumb roots and toes are not mapped.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import simd

public struct LiveMotionRetargeter: Sendable {
    /// cskel27 joint order, as the model decodes it.
    public static let coreJoints = [
        "Hips", "Spine", "Spine1", "Spine2", "Spine3", "Neck", "Head",
        "RightShoulder", "RightArm", "RightForeArm", "RightHand", "RightHandEnd", "RightHandThumb1",
        "LeftShoulder", "LeftArm", "LeftForeArm", "LeftHand", "LeftHandEnd", "LeftHandThumb1",
        "RightUpLeg", "RightLeg", "RightFoot", "RightToeBase",
        "LeftUpLeg", "LeftLeg", "LeftFoot", "LeftToeBase"
    ]
    public static let jointCount = 27

    /// Driven humanoid bone → (core joint index, VRM parent bone). The local
    /// rotation is parent-core⁻¹ · core, so a skipped core joint (Spine2)
    /// is absorbed by its child.
    public static let drivenBones: [(bone: VRMHumanoidBone, core: Int, parent: VRMHumanoidBone?)] =
        [
            (.hips, 0, nil), (.spine, 1, .hips), (.chest, 2, .spine), (.upperChest, 4, .chest),
            (.neck, 5, .upperChest), (.head, 6, .neck),
            (.leftShoulder, 13, .upperChest), (.leftUpperArm, 14, .leftShoulder),
            (.leftLowerArm, 15, .leftUpperArm), (.leftHand, 16, .leftLowerArm),
            (.rightShoulder, 7, .upperChest), (.rightUpperArm, 8, .rightShoulder),
            (.rightLowerArm, 9, .rightUpperArm), (.rightHand, 10, .rightLowerArm),
            (.leftUpperLeg, 23, .hips), (.leftLowerLeg, 24, .leftUpperLeg),
            (.leftFoot, 25, .leftLowerLeg),
            (.rightUpperLeg, 19, .hips), (.rightLowerLeg, 20, .rightUpperLeg),
            (.rightFoot, 21, .rightLowerLeg)
        ]

    /// The reference skeleton the Phase 0 clips were written against: hips
    /// 0.9 m up, feet 0.08 m; ARDY's neutral stands hips 0.896 m above the
    /// feet with the feet 0.07 m off the floor.
    static let referenceHipsHeight: Float = 0.9
    static let referenceFootHeight: Float = 0.08
    static let coreHipsToFoot: Float = 0.896
    static let coreFootHeight: Float = 0.07
    static let legScale = (referenceHipsHeight - referenceFootHeight) / coreHipsToFoot

    /// ARDY has no fingers; while a stream plays the index to little fingers
    /// hold a relaxed curl (text-to-vrma's: proximal 14°, intermediate 17°,
    /// distal 10° about Z, negative on the left hand).
    public static let fingerCurlDegrees: [String: Float] = ["Proximal": 14, "Intermediate": 17, "Distal": 10]

    /// Mocap arms sink into anime torsos; the upper arms open outward by this much.
    public var armSpreadDegrees: Float = 6
    /// Root x/z are pinned so the character gestures in place; y (crouches, bows) is kept.
    public var pinsRootInPlace = true

    private struct BoneTarget {
        let coreIndex: Int
        let parentCoreIndex: Int?
        let modelRest: simd_quatf
        let parentWorldRest: simd_quatf
        let spreadSign: Float
    }

    private let targets: [BoneTarget]
    private let fingerTargets: [(bone: VRMHumanoidBone, target: BoneTarget, degrees: Float)]
    private let convertForVRM0: Bool
    private let hipsRest: SIMD3<Float>
    private let hipsDeltaScale: Float

    /// Bones this retargeter can drive on its model, in `drivenBones` order
    /// (a model missing optional bones such as upperChest drives fewer).
    public let bones: [VRMHumanoidBone]

    public init(model: VRMModel) {
        let rests = buildModelRestTransforms(model: model)
        let parentWorld = buildModelParentWorldRotations(model: model)
        var targets: [BoneTarget] = []
        var bones: [VRMHumanoidBone] = []
        for entry in Self.drivenBones {
            guard let rest = rests[entry.bone] else { continue }
            let parentCore = entry.parent.flatMap { parent in
                Self.drivenBones.first { $0.bone == parent }?.core
            }
            let spread: Float =
                entry.bone == .leftUpperArm ? 1 : entry.bone == .rightUpperArm ? -1 : 0
            targets.append(
                BoneTarget(
                    coreIndex: entry.core, parentCoreIndex: parentCore,
                    modelRest: simd_normalize(rest.rotation),
                    parentWorldRest: simd_normalize(
                        parentWorld[entry.bone] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)),
                    spreadSign: spread))
            bones.append(entry.bone)
        }
        self.targets = targets
        self.bones = bones
        var fingers: [(bone: VRMHumanoidBone, target: BoneTarget, degrees: Float)] = []
        for bone in VRMHumanoidBone.allCases {
            let name = bone.rawValue
            guard let segment = Self.fingerCurlDegrees.first(where: { name.hasSuffix($0.key) }),
                  ["Index", "Middle", "Ring", "Little"].contains(where: { name.contains($0) }), let rest = rests[bone] else { continue }
            let sign: Float = name.hasPrefix("left") ? -1 : 1
            fingers.append((bone, BoneTarget(
                coreIndex: -1, parentCoreIndex: nil, modelRest: simd_normalize(rest.rotation),
                parentWorldRest: simd_normalize(parentWorld[bone] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)), spreadSign: 0), sign * segment.value))
        }
        fingerTargets = fingers
        convertForVRM0 = model.isVRM0
        hipsRest = rests[.hips]?.translation ?? SIMD3<Float>(0, Self.referenceHipsHeight, 0)
        let modelHipsY = rests[.hips]?.translation.y ?? Self.referenceHipsHeight
        hipsDeltaScale =
            modelHipsY > 0.01 ? min(max(modelHipsY / Self.referenceHipsHeight, 0.5), 2.0) : 1
    }

    /// Retargets one decoded frame: 27 row-major 3×3 global rotation
    /// matrices (world = M · local) and the root position in metres.
    public func pose(globalRotations: [Float], rootPosition: SIMD3<Float>) -> LiveMotionPose? {
        guard globalRotations.count >= Self.jointCount * 9 else { return nil }
        func global(_ joint: Int) -> simd_quatf {
            let base = joint * 9
            let matrix = float3x3(rows: [
                SIMD3<Float>(
                    globalRotations[base], globalRotations[base + 1], globalRotations[base + 2]),
                SIMD3<Float>(
                    globalRotations[base + 3], globalRotations[base + 4], globalRotations[base + 5]),
                SIMD3<Float>(
                    globalRotations[base + 6], globalRotations[base + 7], globalRotations[base + 8])
            ])
            return simd_normalize(simd_quatf(matrix))
        }
        let spread = armSpreadDegrees * .pi / 180
        var rotations: [simd_quatf] = []
        rotations.reserveCapacity(targets.count)
        for target in targets {
            var local = global(target.coreIndex)
            if let parent = target.parentCoreIndex {
                local = simd_normalize(simd_inverse(global(parent)) * local)
            }
            if target.spreadSign != 0, spread != 0 {
                local = simd_normalize(
                    simd_quatf(angle: target.spreadSign * spread, axis: SIMD3<Float>(0, 0, 1))
                        * local)
            }
            rotations.append(
                Self.retarget(delta: local, target: target, convertForVRM0: convertForVRM0))
        }
        return LiveMotionPose(
            rotations: rotations, hipsTranslation: hipsTranslation(for: rootPosition))
    }

    /// Constant local rotations holding the relaxed finger curl on this
    /// model, for the finger bones it has.
    public func fingerCurl() -> [(bone: VRMHumanoidBone, rotation: simd_quatf)] {
        fingerTargets.map { finger in
            let delta = simd_quatf(angle: finger.degrees * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
            return (finger.bone, Self.retarget(delta: delta, target: finger.target, convertForVRM0: convertForVRM0))
        }
    }

    /// The loader's rotation retarget for an identity-rest clip: VRM 0.x
    /// flip, conjugation into the parent's rest basis, rest composed last.
    private static func retarget(delta: simd_quatf, target: BoneTarget, convertForVRM0: Bool)
        -> simd_quatf {
        let normalized = convertForVRM0 ? convertRotationForVRM0(delta) : delta
        let localDelta = simd_normalize(
            simd_inverse(target.parentWorldRest) * normalized * target.parentWorldRest)
        return simd_normalize(localDelta * target.modelRest)
    }

    /// The loader's hips translation for the reference skeleton: the root's
    /// offset from the reference rest, scaled by the hips-height ratio.
    private func hipsTranslation(for root: SIMD3<Float>) -> SIMD3<Float> {
        let height = (root.y - Self.coreFootHeight) * Self.legScale + Self.referenceFootHeight
        var offset = SIMD3<Float>(
            pinsRootInPlace ? 0 : root.x * Self.legScale, height - Self.referenceHipsHeight,
            pinsRootInPlace ? 0 : root.z * Self.legScale)
        if convertForVRM0 { offset = convertTranslationForVRM0(offset) }
        return hipsRest + offset * hipsDeltaScale
    }
}
