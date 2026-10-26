//
//  VRMLookAtRanges.swift
//  NeuraLink
//
//  VRMC_vrm lookAt range maps: how far an eye turns, or how strongly a look
//  expression shows, for a gaze angle — min(|angle|, inputMaxValue) /
//  inputMaxValue × outputScale, sign kept. A positive yaw looks to the
//  avatar's left: the left eye uses the outer map and the right eye the
//  inner one (the other way round for a negative yaw); looking down uses
//  the vertical-down map. VRM 0.x's degree maps (xRange → inputMaxValue,
//  yRange → outputScale) read the same way, their curves taken as linear.
//
//  The maps keep the iris on the eye white: VRoid's say 12° of eye turn for
//  a target 90° away. The look-at controller's head and neck follow and its
//  glances are app layers on top; a glance is added after the map and held
//  inside the eye's range.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import simd

enum VRMLookAtRanges {

    /// `angle` (radians) through `map` (degrees), radians out, sign kept.
    static func map(_ angle: Float, _ map: VRMLookAtRangeMap) -> Float {
        let input = abs(angle) * 180 / .pi
        let maxInput = max(map.inputMaxValue, 0.001)
        let degrees = min(input, maxInput) / maxInput * map.outputScale
        return copysign(degrees * .pi / 180, angle)
    }

    /// One eye's yaw and pitch (radians) for a gaze relative to the head.
    /// Without lookAt data the gaze is used as it is.
    static func eyeAngles(
        gazeYaw: Float, gazePitch: Float, glanceYaw: Float, isLeftEye: Bool, pitchDownIsPositive: Bool,
        lookAt: VRMLookAt?
    ) -> (yaw: Float, pitch: Float) {
        guard let lookAt else { return (gazeYaw + glanceYaw, gazePitch) }
        let horizontal = (gazeYaw > 0) == isLeftEye ? lookAt.rangeMapHorizontalOuter : lookAt.rangeMapHorizontalInner
        let lookingDown = pitchDownIsPositive ? gazePitch > 0 : gazePitch < 0
        let vertical = lookingDown ? lookAt.rangeMapVerticalDown : lookAt.rangeMapVerticalUp
        let yawLimit = max(lookAt.rangeMapHorizontalOuter.outputScale, lookAt.rangeMapHorizontalInner.outputScale)
            * .pi / 180
        let yaw = min(max(map(gazeYaw, horizontal) + glanceYaw, -yawLimit), yawLimit)
        return (yaw, map(gazePitch, vertical))
    }

    /// The look presets' weights for a gaze (lookAt type expression): the
    /// side looked to and the direction up or down get the mapped weight,
    /// the opposite preset 0.
    static func expressionWeights(
        yaw: Float, pitch: Float, pitchDownIsPositive: Bool, lookAt: VRMLookAt
    ) -> [VRMExpressionPreset: Float] {
        let horizontal = abs(map(yaw, lookAt.rangeMapHorizontalOuter)) * 180 / .pi
        let lookingDown = pitchDownIsPositive ? pitch > 0 : pitch < 0
        let vertical = abs(map(pitch, lookingDown ? lookAt.rangeMapVerticalDown : lookAt.rangeMapVerticalUp))
            * 180 / .pi
        return [
            .lookLeft: yaw > 0 ? horizontal : 0, .lookRight: yaw < 0 ? horizontal : 0,
            .lookDown: lookingDown ? vertical : 0, .lookUp: !lookingDown && pitch != 0 ? vertical : 0
        ]
    }
}
