//
//  VRMTextureTransform.swift
//  NeuraLink
//
//  A material's UV transform (KHR_texture_transform): uv' = offset +
//  R(rotation) · (scale · uv), R counter-clockwise, applied after MToon's UV
//  animation and to every UV-mapped texture of the material (the matcap is
//  mapped by the view normal and is left alone). One per material, as
//  UniVRM authors it — Unity has one _MainTex_ST — and as every file
//  checked so far writes it: the base colour texture's transform, else the
//  first other texture's. VRM 0.x keeps it as `_MainTex`
//  [offsetX, offsetY, scaleX, scaleY] in Unity's bottom-left UV space.
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import simd

public struct VRMTextureTransform: Equatable, Sendable {
    public var offset = SIMD2<Float>(0, 0)
    /// Radians, counter-clockwise.
    public var rotation: Float = 0
    public var scale = SIMD2<Float>(1, 1)

    public init() {}

    public init(offset: SIMD2<Float>, rotation: Float, scale: SIMD2<Float>) {
        self.offset = offset
        self.rotation = rotation
        self.scale = scale
    }

    public var isIdentity: Bool { offset == .zero && rotation == 0 && scale == SIMD2(1, 1) }

    /// The 2×3 matrix as rows: u' = row0 · (u, v, 1), v' = row1 · (u, v, 1).
    public var rows: (SIMD3<Float>, SIMD3<Float>) {
        let cosine = cos(rotation), sine = sin(rotation)
        return (SIMD3(cosine * scale.x, -sine * scale.y, offset.x), SIMD3(sine * scale.x, cosine * scale.y, offset.y))
    }

    /// From a textureInfo's `extensions` (glTF or MToon); nil without
    /// KHR_texture_transform.
    init?(extensions: [String: Any]?) {
        guard let transform = extensions?["KHR_texture_transform"] as? [String: Any] else { return nil }
        if let offset = Self.floats(transform["offset"]), offset.count == 2 { self.offset = SIMD2(offset[0], offset[1]) }
        if let rotation = transform["rotation"] as? NSNumber { self.rotation = rotation.floatValue }
        if let scale = Self.floats(transform["scale"]), scale.count == 2 { self.scale = SIMD2(scale[0], scale[1]) }
    }

    /// VRM 0.x `_MainTex` [offsetX, offsetY, scaleX, scaleY], in Unity's
    /// bottom-left UV space; glTF's V runs top-down, so
    /// v' = v·sy + (1 − sy − oy) (as three-vrm imports it).
    init?(vrm0MainTex vector: [Float]) {
        guard vector.count == 4 else { return nil }
        offset = SIMD2(vector[0], 1 - vector[3] - vector[1])
        scale = SIMD2(vector[2], vector[3])
    }

    private static func floats(_ value: Any?) -> [Float]? {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue }
    }
}

extension VRMTextureTransform {
    /// The transform `material` declares: its base colour texture's, else
    /// its normal or emissive texture's, else one of its MToon textures'.
    static func declared(by material: GLTFMaterial) -> VRMTextureTransform? {
        let gltfInfos: [[String: Any]?] = [
            material.pbrMetallicRoughness?.baseColorTexture?.extensions?.mapValues(\.value),
            material.normalTexture?.extensions?.mapValues(\.value),
            material.emissiveTexture?.extensions?.mapValues(\.value)
        ]
        let mtoon = material.extensions?["VRMC_materials_mtoon"] as? [String: Any]
        let mtoonInfos: [[String: Any]?] = (mtoon?.values.compactMap { $0 as? [String: Any] } ?? [])
            .map { $0["extensions"] as? [String: Any] }
        return (gltfInfos + mtoonInfos).lazy.compactMap { VRMTextureTransform(extensions: $0) }.first
    }
}
