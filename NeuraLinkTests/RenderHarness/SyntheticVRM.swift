//
//  SyntheticVRM.swift
//  NeuraLinkTests
//
//  Builds the smallest VRM 1.0 GLB the loader accepts — the fifteen required
//  humanoid bones, one skinned quad, one material — so a render probe can put
//  exactly the texture, alpha mode and MToon factors it is testing in front
//  of the camera. Skinned on purpose: avatars draw through the skinned
//  pipelines, so that is the path the probes must exercise.
//
//  Created by Dedicatus on 22/10/2026.
//

import Foundation
import simd

struct SyntheticVRM {

    /// PNGs embedded in the GLB; texture `i` samples image `i`.
    var images: [Data] = []
    /// The quad's material as glTF JSON. Texture indices refer to `images`.
    var material: [String: Any]
    /// Quad centre and size in meters; the quad faces +Z.
    var center = SIMD3<Float>(0, 1, 0)
    var size = SIMD2<Float>(1, 1)
    /// Shading normal of every vertex. The quad still faces +Z on screen;
    /// tilting this only changes how it is lit.
    var normal = SIMD3<Float>(0, 0, 1)
    /// glTF sampler for every texture (default: linear, mipmapped, repeat).
    var sampler: [String: Any] = ["magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497]

    // MARK: - Materials

    /// An MToon 1.0 material. `mtoon` entries override the neutral defaults
    /// (shade = lit, so lighting reads as plain brightness).
    static func mtoon(
        base: SIMD4<Float> = [1, 1, 1, 1], baseTexture: Int? = nil, alphaMode: String = "OPAQUE",
        alphaCutoff: Float = 0.5, mtoon: [String: Any] = [:], extra: [String: Any] = [:]
    ) -> [String: Any] {
        var pbr: [String: Any] = [
            "baseColorFactor": [Double(base.x), Double(base.y), Double(base.z), Double(base.w)], "metallicFactor": 0.0
        ]
        if let baseTexture { pbr["baseColorTexture"] = ["index": baseTexture] }
        var ext: [String: Any] = [
            "specVersion": "1.0",
            "shadeColorFactor": [Double(base.x), Double(base.y), Double(base.z)],
            "shadingToonyFactor": 0.9, "shadingShiftFactor": 0.0, "giEqualizationFactor": 0.9,
            "outlineWidthMode": "none", "outlineWidthFactor": 0.0,
            "parametricRimColorFactor": [0.0, 0.0, 0.0], "rimLightingMixFactor": 1.0,
            "matcapFactor": [0.0, 0.0, 0.0]
        ]
        if let baseTexture { ext["shadeMultiplyTexture"] = ["index": baseTexture] }
        for (key, value) in mtoon { ext[key] = value }
        var material: [String: Any] = [
            "name": "probe", "pbrMetallicRoughness": pbr, "alphaMode": alphaMode, "doubleSided": true,
            "extensions": ["VRMC_materials_mtoon": ext]
        ]
        if alphaMode == "MASK" { material["alphaCutoff"] = Double(alphaCutoff) }
        for (key, value) in extra { material[key] = value }
        return material
    }

    // MARK: - GLB

    func glb() -> Data {
        var bin = Data()
        var views: [[String: Any]] = []
        func addView(_ bytes: Data, target: Int? = nil) -> Int {
            while bin.count % 4 != 0 { bin.append(0) }
            var view: [String: Any] = ["buffer": 0, "byteOffset": bin.count, "byteLength": bytes.count]
            if let target { view["target"] = target }
            bin.append(bytes)
            views.append(view)
            return views.count - 1
        }
        let half = size / 2
        let corners: [SIMD3<Float>] = [
            center + [-half.x, half.y, 0], center + [half.x, half.y, 0],
            center + [half.x, -half.y, 0], center + [-half.x, -half.y, 0]
        ]
        let positions = addView(Self.floats(corners.flatMap { [$0.x, $0.y, $0.z] }), target: 34_962)
        let normals = addView(Self.floats(Array(repeating: [normal.x, normal.y, normal.z], count: 4).flatMap { $0 }), target: 34_962)
        let uvs = addView(Self.floats([0, 0, 1, 0, 1, 1, 0, 1]), target: 34_962)
        let joints = addView(Self.shorts(Array(repeating: 0, count: 16)), target: 34_962)
        let weights = addView(Self.floats(Array(repeating: [Float(1), 0, 0, 0], count: 4).flatMap { $0 }), target: 34_962)
        let indices = addView(Self.shorts([0, 3, 2, 0, 2, 1]), target: 34_963)
        let inverseBind = addView(Self.floats([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]))
        let imageViews = images.map { addView($0) }

        let minCorner = corners.reduce(corners[0]) { simd_min($0, $1) }
        let maxCorner = corners.reduce(corners[0]) { simd_max($0, $1) }
        let accessors: [[String: Any]] = [
            ["bufferView": positions, "componentType": 5126, "count": 4, "type": "VEC3",
             "min": [minCorner.x, minCorner.y, minCorner.z].map(Double.init),
             "max": [maxCorner.x, maxCorner.y, maxCorner.z].map(Double.init)],
            ["bufferView": normals, "componentType": 5126, "count": 4, "type": "VEC3"],
            ["bufferView": uvs, "componentType": 5126, "count": 4, "type": "VEC2"],
            ["bufferView": joints, "componentType": 5123, "count": 4, "type": "VEC4"],
            ["bufferView": weights, "componentType": 5126, "count": 4, "type": "VEC4"],
            ["bufferView": indices, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ["bufferView": inverseBind, "componentType": 5126, "count": 1, "type": "MAT4"]
        ]

        let bones = Self.requiredBones
        var nodes: [[String: Any]] = [["name": "hips", "children": Array(1..<bones.count)]]
        nodes += bones.dropFirst().map { ["name": $0] }
        nodes.append(["name": "probe_mesh", "mesh": 0, "skin": 0])
        var humanBones: [String: Any] = [:]
        for (index, bone) in bones.enumerated() { humanBones[bone] = ["node": index] }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "NeuraLinkTests.SyntheticVRM"],
            "scene": 0, "scenes": [["nodes": [0, nodes.count - 1]]],
            "nodes": nodes,
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2, "JOINTS_0": 3, "WEIGHTS_0": 4],
                "indices": 5, "material": 0
            ]]]],
            "skins": [["joints": [0], "inverseBindMatrices": 6, "skeleton": 0]],
            "materials": [material],
            "accessors": accessors,
            "bufferViews": views,
            "buffers": [["byteLength": bin.count]],
            "extensionsUsed": ["VRMC_vrm", "VRMC_materials_mtoon"],
            "extensions": ["VRMC_vrm": [
                "specVersion": "1.0",
                "meta": ["name": "probe", "authors": ["NeuraLinkTests"], "licenseUrl": "https://vrm.dev/licenses/1.0/"],
                "humanoid": ["humanBones": humanBones]
            ]]
        ]
        if !images.isEmpty {
            json["images"] = imageViews.map { ["bufferView": $0, "mimeType": "image/png"] }
            json["samplers"] = [sampler]
            json["textures"] = images.indices.map { ["source": $0, "sampler": 0] }
        }
        // swiftlint:disable:next force_try
        var jsonData = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        while bin.count % 4 != 0 { bin.append(0) }

        var glb = Data()
        glb.appendLE(0x4654_6C67)  // "glTF"
        glb.appendLE(2)
        glb.appendLE(UInt32(12 + 8 + jsonData.count + 8 + bin.count))
        glb.appendLE(UInt32(jsonData.count))
        glb.appendLE(0x4E4F_534A)  // "JSON"
        glb.append(jsonData)
        glb.appendLE(UInt32(bin.count))
        glb.appendLE(0x004E_4942)  // "BIN\0"
        glb.append(bin)
        return glb
    }

    static let requiredBones = [
        "hips", "spine", "head",
        "leftUpperArm", "leftLowerArm", "leftHand", "rightUpperArm", "rightLowerArm", "rightHand",
        "leftUpperLeg", "leftLowerLeg", "leftFoot", "rightUpperLeg", "rightLowerLeg", "rightFoot"
    ]

    private static func floats(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func shorts(_ values: [UInt16]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
