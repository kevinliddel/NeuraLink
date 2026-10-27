//
//  VRMModel+TextureRoles.swift
//  NeuraLink
//
//  Which textures hold data rather than colour. Those load as linear
//  (`.rgba8Unorm`); everything else is sRGB colour. Decoding a data map as
//  sRGB bends its values (a shading-shift gray of 0.5 reads as 0.22), which
//  moves the shade line the artist placed.
//
//  Data maps: glTF normal maps, and the MToon maps the spec treats as
//  non-colour — VRM 1.0 `shadingShiftTexture`, `outlineWidthMultiplyTexture`,
//  `uvAnimationMaskTexture`; their VRM 0.x counterparts the converter reads,
//  `_OutlineWidthTexture` and `_UvAnimMaskTexture`. A texture that also feeds
//  a colour slot stays sRGB (logged): colour is what the eye sees.
//
//  Created by Dedicatus on 22/10/2026.
//

import Foundation

extension VRMModel {

    static func linearTextureIndices(in gltf: GLTFDocument) -> Set<Int> {
        var data = Set<Int>()
        var colour = Set<Int>()
        for material in gltf.materials ?? [] {
            if let normal = material.normalTexture { data.insert(normal.index) }
            if let base = material.pbrMetallicRoughness?.baseColorTexture { colour.insert(base.index) }
            if let emissive = material.emissiveTexture { colour.insert(emissive.index) }
            guard let mtoon = material.extensions?["VRMC_materials_mtoon"] as? [String: Any] else { continue }
            for key in ["shadingShiftTexture", "outlineWidthMultiplyTexture", "uvAnimationMaskTexture"] {
                if let index = textureIndex(mtoon[key]) { data.insert(index) }
            }
            for key in ["shadeMultiplyTexture", "matcapTexture", "rimMultiplyTexture"] {
                if let index = textureIndex(mtoon[key]) { colour.insert(index) }
            }
        }
        let vrm0 = (gltf.extensions?["VRM"] as? [String: Any])?["materialProperties"] as? [[String: Any]] ?? []
        for properties in vrm0 {
            guard let textures = properties["textureProperties"] as? [String: Any] else { continue }
            for key in ["_OutlineWidthTexture", "_UvAnimMaskTexture"] {
                if let index = (textures[key] as? NSNumber)?.intValue { data.insert(index) }
            }
            for key in ["_MainTex", "_ShadeTexture", "_EmissionMap", "_SphereAdd", "_RimTexture"] {
                if let index = (textures[key] as? NSNumber)?.intValue { colour.insert(index) }
            }
        }
        let shared = data.intersection(colour)
        if !shared.isEmpty {
            nlLog("[VRMModel] Textures \(shared.sorted()) feed both colour and data slots; kept sRGB", level: .warning)
        }
        return data.subtracting(colour)
    }

    private static func textureIndex(_ info: Any?) -> Int? {
        ((info as? [String: Any])?["index"] as? NSNumber)?.intValue
    }
}
