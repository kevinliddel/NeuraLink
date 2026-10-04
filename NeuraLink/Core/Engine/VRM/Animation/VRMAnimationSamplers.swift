//
//  VRMAnimationSamplers.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - Sampler Factories

/// Builds a rotation sampler that retargets a VRMA track onto the model.
///
/// Step 1 — normalize (animation side). VRMC_vrm_animation requires the
/// humanoid rest pose to be a T-pose but lets its nodes carry ANY rest
/// rotation (Mixamo / FBX2glTF and UniGLTF exports do; VRoid / three-vrm
/// exports are identity). The world-aligned rotation is
///   normalized = animParentWorldRest · q · inv(animParentWorldRest · animRest)
/// — three-vrm VRMAnimationLoaderPlugin. With identity rests it is just q.
/// VRM 0.x targets flip the NORMALIZED rotation (x, z negated).
///
/// Step 2 — retarget (model side), see the formula below.
///
/// For VRM 1.x thumbs: the metacarpal node's `rotation` in the GLTF already encodes the
/// 45° T-pose spread, so `modelRest` captures it and the formula handles the delta naturally.
/// No additional corrective angle is needed or correct here — that would double-apply the offset.
/// (The proximal→metacarpal bone remapping in VRMAnimationLoader ensures the right node is driven.)
func makeRotationSampler(
    track: KeyTrack,
    animRest: simd_quatf,
    modelRest: simd_quatf?,
    parentWorldRest: simd_quatf? = nil,
    animParentWorldRest: simd_quatf? = nil,
    convertForVRM0: Bool = false
) -> (Float) -> simd_quatf {
    let animParent = simd_normalize(animParentWorldRest ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    let inverseAnimWorldRest = simd_inverse(simd_normalize(animParent * simd_normalize(animRest)))
    let normalizedModelRest = modelRest.map { simd_normalize($0) }
    let basis = parentWorldRest.map { simd_normalize($0) }

    return { t in
        var delta = simd_normalize(animParent * sampleQuaternion(track, at: t) * inverseAnimWorldRest)
        if convertForVRM0 {
            delta = convertRotationForVRM0(delta)
        }

        guard let modelRestNorm = normalizedModelRest else { return delta }

        // Spec retarget (three-vrm humanoid rig / UniVRM control rig):
        //   rawLocal = inv(parentWorldRest) · delta · parentWorldRest · restLocal
        // VRMA deltas live in normalized (T-pose, world-aligned) space;
        // conjugating by the parent's world rest moves them into the bone's
        // parent space, and composing the rest LAST keeps baked rest
        // rotations (e.g. VRoid's ~45° thumb-metacarpal spread) from
        // re-rotating the delta — the old `restLocal · delta` order did
        // exactly that, which the ±25° VRoid thumb hack used to fight.
        let localDelta: simd_quatf
        if let basis {
            localDelta = simd_normalize(simd_inverse(basis) * delta * basis)
        } else {
            localDelta = delta
        }
        return simd_normalize(localDelta * modelRestNorm)
    }
}

/// Hips translation: the offset from the animation's rest, expressed in
/// world axes (rotated by the animation's parent world rest), flipped for
/// VRM 0.x, scaled by the hips-height ratio and added to the model's rest.
func makeTranslationSampler(
    track: KeyTrack,
    animRest: SIMD3<Float>,
    modelRest: SIMD3<Float>?,
    animParentWorldRest: simd_quatf? = nil,
    convertForVRM0: Bool = false,
    deltaScale: Float = 1
) -> (Float) -> SIMD3<Float> {
    let animParent = simd_normalize(animParentWorldRest ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    return { t in
        let sample = sampleVector3(track, at: t)
        guard let modelRest else {
            return convertForVRM0 ? convertTranslationForVRM0(sample) : sample
        }
        var offset = animParent.act(sample - animRest)
        if convertForVRM0 { offset = convertTranslationForVRM0(offset) }
        // deltaScale: VRMC_vrm_animation retargets hips translation by the
        // hips-height ratio between model and animation, so bob amplitude
        // and root-motion stride match the target's proportions.
        return modelRest + offset * deltaScale
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
