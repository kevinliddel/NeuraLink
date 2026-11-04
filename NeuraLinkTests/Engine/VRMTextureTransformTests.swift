//
//  VRMTextureTransformTests.swift
//  NeuraLinkTests
//
//  The material UV transform: KHR_texture_transform's matrix (offset +
//  counter-clockwise rotation · scale), VRM 0.x `_MainTex` moved out of
//  Unity's bottom-left UV space, and which texture's transform a material
//  takes.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import Testing
import simd
@testable import NeuraLink

@Suite("VRM texture transform")
struct VRMTextureTransformTests {

    private func apply(_ transform: VRMTextureTransform, _ uv: SIMD2<Float>) -> SIMD2<Float> {
        let (row0, row1) = transform.rows
        let point = SIMD3<Float>(uv, 1)
        return SIMD2(simd_dot(row0, point), simd_dot(row1, point))
    }

    @Test("Offset + counter-clockwise rotation · scale, in that order")
    func matrix() {
        let transform = VRMTextureTransform(offset: [0.5, 0.25], rotation: .pi / 2, scale: [2, 3])
        // (1, 0) scaled to (2, 0), turned a quarter counter-clockwise to (0, 2), then offset.
        let result = apply(transform, [1, 0])
        #expect(simd_distance(result, [0.5, 2.25]) < 1e-5, "\(result)")
        #expect(VRMTextureTransform().isIdentity)
        #expect(simd_distance(apply(VRMTextureTransform(), [0.3, 0.7]), [0.3, 0.7]) < 1e-6)
    }

    @Test("VRM 0.x _MainTex is applied in Unity's flipped V and lands on the same texel")
    func vrm0MainTex() throws {
        let transform = try #require(VRMTextureTransform(vrm0MainTex: [0.1, 0.2, 2, 3]))
        // Unity: v_u' = v_u·3 + 0.2 with v_u = 1 − v. Back in glTF: v' = 1 − v_u'.
        let uv = SIMD2<Float>(0.4, 0.3)
        let unityV = (1 - uv.y) * 3 + 0.2
        let expected = SIMD2<Float>(uv.x * 2 + 0.1, 1 - unityV)
        #expect(simd_distance(apply(transform, uv), expected) < 1e-5)
        #expect(VRMTextureTransform(vrm0MainTex: [0, 0, 1, 1])?.isIdentity == true)
    }

    @Test("A material takes its base colour texture's transform")
    func declaredByMaterial() throws {
        let json = """
        {"name": "m", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0, "extensions":
          {"KHR_texture_transform": {"offset": [0.25, 0.5], "rotation": 0.5, "scale": [2, 4]}}}}}
        """
        let material = try JSONDecoder().decode(GLTFMaterial.self, from: Data(json.utf8))
        let transform = try #require(VRMTextureTransform.declared(by: material))
        #expect(transform == VRMTextureTransform(offset: [0.25, 0.5], rotation: 0.5, scale: [2, 4]))
        let plain = try JSONDecoder().decode(GLTFMaterial.self, from: Data(#"{"name": "p"}"#.utf8))
        #expect(VRMTextureTransform.declared(by: plain) == nil)
    }
}
