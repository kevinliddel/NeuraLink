//
//  VRMPalm.swift
//  NeuraLink
//
//  A hand's palm, measured from its humanoid finger bones in the hand's own
//  rest frame. A held prop is placed against it rather than against the hand
//  bone: rigs differ in hand size (VRoid girls ~6 cm wrist to knuckles, men
//  up to 8) and in where the palm sits around the bone, so one hand-bone
//  offset that seats the phone in Sonya's palm sinks it into a man's fingers
//  and floats it above a small hand.
//
//  Frame: origin at the palm's centre (half way to the middle knuckle, a
//  third of the way to the thumb), +X toward the fingertips, +Y out of the
//  palm, +Z = X × Y. Size: wrist to the middle-finger knuckle.
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import simd

public struct VRMPalm: Equatable {
    /// Palm centre in the hand bone's local frame.
    public let origin: SIMD3<Float>
    /// Palm axes in the hand bone's local frame.
    public let rotation: simd_quatf
    /// Wrist to middle-finger knuckle, metres.
    public let size: Float

    public init(origin: SIMD3<Float>, rotation: simd_quatf, size: Float) {
        self.origin = origin
        self.rotation = rotation
        self.size = size
    }

    /// The palm `hand` of `model` has, or nil without the finger bones.
    static func measure(in model: VRMModel, hand: VRMHumanoidBone) -> VRMPalm? {
        let isRight: Bool
        let fingers: (middle: VRMHumanoidBone, index: VRMHumanoidBone, little: VRMHumanoidBone,
                      thumb: VRMHumanoidBone, thumbFallback: VRMHumanoidBone)
        switch hand {
        case .rightHand:
            isRight = true
            fingers = (.rightMiddleProximal, .rightIndexProximal, .rightLittleProximal,
                       .rightThumbMetacarpal, .rightThumbProximal)
        case .leftHand:
            isRight = false
            fingers = (.leftMiddleProximal, .leftIndexProximal, .leftLittleProximal,
                       .leftThumbMetacarpal, .leftThumbProximal)
        default:
            return nil
        }
        func node(_ bone: VRMHumanoidBone) -> VRMNode? {
            model.humanoid?.getBoneNode(bone).flatMap { model.nodes[safe: $0] }
        }
        guard let handNode = node(hand), let middle = node(fingers.middle), let index = node(fingers.index),
              let little = node(fingers.little), let thumb = node(fingers.thumb) ?? node(fingers.thumbFallback)
        else { return nil }
        // Positions in the hand's rest frame. The finger roots are the hand's
        // children, so they keep these positions in any pose.
        let toHand = restWorldMatrix(of: handNode).inverse
        func local(_ node: VRMNode) -> SIMD3<Float> {
            let point = toHand * restWorldMatrix(of: node).columns.3
            return SIMD3(point.x, point.y, point.z)
        }
        let middleKnuckle = local(middle)
        let size = simd_length(middleKnuckle)
        guard size > 1e-4 else { return nil }
        let towardFingers = middleKnuckle / size
        let across = local(index) - local(little)
        // Index − little runs toward the thumb; with the fingers it spans the
        // palm, and their cross product points out of the back of a right
        // hand (out of the palm of a left one).
        let cross = simd_cross(towardFingers, across)
        guard simd_length(cross) > 1e-6 else { return nil }
        var outOfPalm = simd_normalize(isRight ? -cross : cross)
        outOfPalm = simd_normalize(outOfPalm - simd_dot(outOfPalm, towardFingers) * towardFingers)
        let third = simd_cross(towardFingers, outOfPalm)
        return VRMPalm(
            origin: 0.5 * middleKnuckle + 0.3 * local(thumb),
            rotation: simd_normalize(simd_quatf(simd_float3x3(towardFingers, outOfPalm, third))),
            size: size)
    }

    /// `grip`, authored against `reference`'s palm, placed on this palm:
    /// same pose relative to the palm, offsets and prop size scaled by the
    /// hand's size. The result is in the hand bone's local frame.
    func place(_ grip: VRMPropGrip, authoredOn reference: VRMPalm) -> VRMPropGrip {
        let ratio = size / reference.size
        let inPalmRotation = reference.rotation.inverse * grip.rotation
        let inPalmOffset = reference.rotation.inverse.act(grip.translation - reference.origin)
        return VRMPropGrip(
            translation: origin + rotation.act(inPalmOffset * ratio),
            rotation: simd_normalize(rotation * inPalmRotation),
            scale: grip.scale * ratio)
    }

    /// A node's world transform in the file's rest pose.
    static func restWorldMatrix(of node: VRMNode) -> simd_float4x4 {
        var matrix = restLocalMatrix(of: node)
        var ancestor = node.parent
        while let parent = ancestor {
            matrix = restLocalMatrix(of: parent) * matrix
            ancestor = parent.parent
        }
        return matrix
    }

    private static func restLocalMatrix(of node: VRMNode) -> simd_float4x4 {
        var matrix = simd_float4x4(node.initialRotation)
        matrix.columns.0 *= node.initialScale.x
        matrix.columns.1 *= node.initialScale.y
        matrix.columns.2 *= node.initialScale.z
        matrix.columns.3 = SIMD4<Float>(node.initialTranslation, 1)
        return matrix
    }
}
