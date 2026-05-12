//
//  VRMAnimationSamplers.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - Sampler Factories

/// Builds a rotation sampler that applies delta-based retargeting from animation rest to model rest.
/// VRM spec: delta = inv(animRest) * animRotation; result = modelRest * delta
func makeRotationSampler(
    track: KeyTrack,
    animRest: simd_quatf,
    modelRest: simd_quatf?,
    bone: VRMHumanoidBone? = nil,
    convertForVRM0: Bool = false
) -> (Float) -> simd_quatf {
    let normalizedAnimRest  = simd_normalize(animRest)
    let normalizedModelRest = modelRest.map { simd_normalize($0) }

    return { t in
        var q = sampleQuaternion(track, at: t)
        if convertForVRM0 { 
            q = convertRotationForVRM0(q) 
        } else if let bone = bone {
            // VRM 1.0 Thumb Alignment Fix:
            // VRM 1.0 specifies a 45-degree thumb orientation in T-pose. Standard animations 
            // often assume a flatter thumb, which causes the thumb to 'raise up' or twist 
            // towards the back of the hand. We apply a corrective pitch/roll to re-align them.
            if bone == .leftThumbProximal || bone == .leftThumbMetacarpal {
                let correction = simd_quatf(angle: -18.0 * .pi / 180.0, axis: SIMD3<Float>(0, 0, 1))
                q = q * correction
            } else if bone == .rightThumbProximal || bone == .rightThumbMetacarpal {
                let correction = simd_quatf(angle: 18.0 * .pi / 180.0, axis: SIMD3<Float>(0, 0, 1))
                q = q * correction
            }
        }
        
        guard let modelRestNorm = normalizedModelRest else { return q }
        
        // VRM Spec: result = modelRest * (inv(animRest) * q)
        let delta = simd_normalize(simd_inverse(normalizedAnimRest) * q)
        return simd_normalize(modelRestNorm * delta)
    }
}

func makeTranslationSampler(
    track: KeyTrack,
    animRest: SIMD3<Float>,
    modelRest: SIMD3<Float>?,
    convertForVRM0: Bool = false
) -> (Float) -> SIMD3<Float> {
    return { t in
        var v = sampleVector3(track, at: t)
        if convertForVRM0 { v = convertTranslationForVRM0(v) }
        guard let modelRest else { return v }
        return modelRest + (v - animRest)
    }
}

func makeScaleSampler(
    track: KeyTrack,
    animRest: SIMD3<Float>,
    modelRest: SIMD3<Float>?
) -> (Float) -> SIMD3<Float> {
    return { t in
        let animScale = sampleVector3(track, at: t)
        guard let modelRest else { return animScale }
        return modelRest * safeDivide(animScale, by: animRest)
    }
}

/// Expression weight is encoded as translation.x (0–1) in VRMA format.
func makeExpressionWeightSampler(track: KeyTrack) -> (Float) -> Float {
    return { t in sampleVector3(track, at: t).x }
}

// MARK: - VRM 0.0 Coordinate Conversion

/// VRM 0.0 uses Unity left-handed coords; VRMA uses glTF right-handed.
/// Negates X and Z per three-vrm createVRMAnimationClip.ts
func convertRotationForVRM0(_ q: simd_quatf) -> simd_quatf {
    simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: -q.imag.z, r: q.real)
}

func convertTranslationForVRM0(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(-v.x, v.y, -v.z)
}

// MARK: - Math Utilities

func safeDivide(_ a: SIMD3<Float>, by b: SIMD3<Float>) -> SIMD3<Float> {
    let eps: Float = 1e-6
    return SIMD3<Float>(
        a.x / (abs(b.x) > eps ? b.x : 1),
        a.y / (abs(b.y) > eps ? b.y : 1),
        a.z / (abs(b.z) > eps ? b.z : 1))
}

extension Float {
    var degreesToRadians: Float { self * .pi / 180.0 }
    var radiansToDegrees: Float { self * 180.0 / .pi }
}
