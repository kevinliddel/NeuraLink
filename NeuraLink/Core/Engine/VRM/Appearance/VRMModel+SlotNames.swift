//
//  VRMModel+SlotNames.swift
//  NeuraLink
//
//  Customization-slot lookup for a loaded model's materials. Older VRoid
//  exports (UniGLTF 1.x) name every glTF material "VRM/MToon" and keep the
//  real part names only in the VRM 0.x materialProperties block, so the
//  slot classifier is fed that name when the glTF one is generic. Grafted
//  copies carry the slot resolved on the donor side (`slotHint`).
//

import Foundation

extension VRMModel {

    /// The name to classify a material by: glTF name unless generic, then
    /// the paired VRM 0.x material property name.
    public func slotMaterialName(at index: Int) -> String? {
        guard index < materials.count else { return nil }
        let gltfName = materials[index].name
        if let gltfName, !Self.isGenericMaterialName(gltfName) { return gltfName }
        if let property = vrm0MaterialProperties.vrm0Property(forMaterialNamed: gltfName, at: index),
            let name = property.name, !Self.isGenericMaterialName(name) {
            return name
        }
        // Last resort — some exports carry no part names at all; a material
        // used only by a "Hair…" mesh is still recognisably hair.
        if let meshName = Self.exclusiveMeshName(forMaterial: index, meshes: meshes.map { ($0.name, $0.primitives.compactMap(\.materialIndex)) }) {
            return meshName
        }
        return gltfName
    }

    /// Name of the single mesh family using this material, when that name
    /// identifies a part ("Hair001.baked" → "Hair"). Nil otherwise.
    nonisolated static func exclusiveMeshName(forMaterial index: Int, meshes: [(name: String?, materials: [Int])]) -> String? {
        let users = meshes.filter { $0.materials.contains(index) }.compactMap { $0.name?.lowercased() }
        guard !users.isEmpty, users.allSatisfy({ $0.contains("hair") }) else { return nil }
        return "Hair"
    }

    /// Customization slot of a material (grafted copies use their hint).
    public func slot(ofMaterial index: Int) -> VRoidMaterialSlot {
        guard index < materials.count else { return .other }
        if let hint = materials[index].slotHint { return hint }
        return VRoidMaterialSlot.classify(materialName: slotMaterialName(at: index))
    }

    /// Shader-ish placeholder names some exporters write instead of the part name.
    nonisolated public static func isGenericMaterialName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.isEmpty || lower.hasPrefix("vrm/") || lower == "standard" || lower == "material"
    }
}
