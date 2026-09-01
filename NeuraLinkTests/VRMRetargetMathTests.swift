//
//  VRMRetargetMathTests.swift
//  NeuraLinkTests
//
//  Pins the humanoid rotation retarget formula:
//    rawLocal = inv(parentWorldRest) · delta · parentWorldRest · restLocal
//  (three-vrm humanoid rig / UniVRM control rig). The composition ORDER and
//  the parent-basis conjugation are exactly what the old ±25° VRoid thumb
//  compensation hack existed to approximate.
//

import Testing
import Foundation
import simd
@testable import NeuraLink

@Suite("VRM retarget math")
struct VRMRetargetMathTests {

    private let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    private func rotationTrack(_ q: simd_quatf) -> KeyTrack {
        KeyTrack(times: [0], values: [q.imag.x, q.imag.y, q.imag.z, q.real],
                 path: "rotation", interpolation: .linear, componentCount: 4)
    }

    private func approxEqual(_ a: simd_quatf, _ b: simd_quatf) -> Bool {
        abs(simd_dot(simd_normalize(a).vector, simd_normalize(b).vector)) > 0.9999
    }

    @Test("Identity normalized pose lands exactly on the bone's rest")
    func identityPoseYieldsRest() {
        let rest = simd_quatf(angle: 45 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        let basis = simd_quatf(angle: 90 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let sampler = makeRotationSampler(
            track: rotationTrack(identity), animRest: identity,
            modelRest: rest, parentWorldRest: basis)
        #expect(approxEqual(sampler(0), rest))
    }

    @Test("Delta composes before the rest (spec order, not rest-first)")
    func deltaComposesBeforeRest() {
        // With an identity parent basis the result must be delta · rest —
        // the old code computed rest · delta, which re-rotates the delta by
        // any baked rest (the VRoid thumb-spread bug).
        let rest = simd_quatf(angle: 45 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        let key = simd_quatf(angle: 30 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let sampler = makeRotationSampler(
            track: rotationTrack(key), animRest: identity,
            modelRest: rest, parentWorldRest: nil)
        #expect(approxEqual(sampler(0), key * rest))
        #expect(!approxEqual(sampler(0), rest * key))
    }

    @Test("Delta is conjugated into the parent's rest basis")
    func deltaConjugatedIntoParentBasis() {
        let rest = simd_quatf(angle: 45 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        let basis = simd_quatf(angle: 90 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let key = simd_quatf(angle: 30 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        let sampler = makeRotationSampler(
            track: rotationTrack(key), animRest: identity,
            modelRest: rest, parentWorldRest: basis)
        let expected = simd_normalize(simd_inverse(basis) * key * basis * rest)
        #expect(approxEqual(sampler(0), expected))
    }

    @Test("Animation rest is removed from the key before retargeting")
    func animRestRemoved() {
        // key == animRest means "no movement" — must land on the rest pose.
        let animRest = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        let rest = simd_quatf(angle: 45 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
        let sampler = makeRotationSampler(
            track: rotationTrack(animRest), animRest: animRest,
            modelRest: rest, parentWorldRest: nil)
        #expect(approxEqual(sampler(0), rest))
    }
}
