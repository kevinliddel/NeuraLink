//
// VRMBuilder.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

/// Builder for creating VRM models from scratch
public class VRMBuilder {

    private var meta: VRMMeta
    private var skeletonPreset: SkeletonPreset = .defaultHumanoid
    var morphValues: [String: Float] = [:]
    private var hairColor: SIMD3<Float> = SIMD3(0.35, 0.25, 0.15)  // Default brown
    private var eyeColor: SIMD3<Float> = SIMD3(0.4, 0.3, 0.2)  // Default brown
    private var skinTone: Float = 0.5  // Default medium
    private var expressions: [VRMExpressionPreset] = []

    // MARK: - Initialization

    public init(meta: VRMMeta? = nil) {
        self.meta = meta ?? VRMMeta.default()
    }

    // MARK: - Configuration

    /// Set the skeleton preset to use
    @discardableResult
    public func setSkeleton(_ preset: SkeletonPreset) -> VRMBuilder {
        self.skeletonPreset = preset
        return self
    }

    /// Apply morph target values (height, muscle, etc.)
    @discardableResult
    public func applyMorphs(_ morphs: [String: Float]) -> VRMBuilder {
        self.morphValues.merge(morphs) { _, new in new }
        return self
    }

    /// Set hair color (RGB 0-1)
    @discardableResult
    public func setHairColor(_ color: SIMD3<Float>) -> VRMBuilder {
        self.hairColor = color
        return self
    }

    /// Set eye color (RGB 0-1)
    @discardableResult
    public func setEyeColor(_ color: SIMD3<Float>) -> VRMBuilder {
        self.eyeColor = color
        return self
    }

    /// Set skin tone (0 = lightest, 1 = darkest)
    @discardableResult
    public func setSkinTone(_ tone: Float) -> VRMBuilder {
        self.skinTone = max(0, min(1, tone))
        return self
    }

    /// Add expression presets to the model
    @discardableResult
    public func addExpressions(_ expressions: [VRMExpressionPreset]) -> VRMBuilder {
        self.expressions = expressions
        return self
    }

    // MARK: - Build

    /// Build the VRM model
    public func build() throws -> VRMModel {
        // Create base glTF document
        let gltfDocument = try buildGLTFDocument()

        // Create VRM humanoid
        let humanoid = try buildHumanoid()

        // Create VRM model
        let model = VRMModel(
            specVersion: .v1_0,
            meta: meta,
            humanoid: humanoid,
            gltf: gltfDocument
        )

        // Parse nodes from glTF document
        if let gltfNodes = gltfDocument.nodes {
            for (index, gltfNode) in gltfNodes.enumerated() {
                let node = VRMNode(index: index, gltfNode: gltfNode)
                model.nodes.append(node)
            }
        }

        // Set expressions
        if !expressions.isEmpty {
            model.expressions = buildExpressions()
        }

        return model
    }

    // MARK: - Private Build Methods

    private func buildGLTFDocument() throws -> GLTFDocument {
        // Build nodes for skeleton
        let nodes = buildNodes()

        // Generate mesh geometry data first
        let meshData = generateHumanoidGeometry()

        // Build material
        let material = buildMaterial()

        // Create buffer with actual binary data
        var allBufferData = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []

        // Helper function to add data to buffer and create buffer view/accessor
        func addAccessor(data: [Any], componentType: Int, type: String, byteLength: Int) -> Int {
            let bufferViewOffset = allBufferData.count

            // Convert data to bytes and append to buffer
            var dataBytes = Data()
            for value in data {
                if let floatValue = value as? Float {
                    let floatBytes = withUnsafeBytes(of: floatValue) { Data($0) }
                    dataBytes.append(floatBytes)
                } else if let uint16Value = value as? UInt16 {
                    let uint16Bytes = withUnsafeBytes(of: uint16Value) { Data($0) }
                    dataBytes.append(uint16Bytes)
                }
            }
            allBufferData.append(dataBytes)

            // Create buffer view
            let bufferView: [String: Any] = [
                "buffer": 0,
                "byteOffset": bufferViewOffset,
                "byteLength": byteLength
            ]
            bufferViews.append(bufferView)

            // Create accessor
            let count =
                type == "VEC3" ? data.count / 3 : (type == "VEC2" ? data.count / 2 : data.count)
            let accessorIndex = accessors.count
            let accessorDict: [String: Any] = [
                "bufferView": accessorIndex,
                "byteOffset": 0,
                "componentType": componentType,
                "count": count,
                "type": type
            ]
            accessors.append(accessorDict)

            return accessorIndex
        }

        // Add position accessor
        let positionIndex = addAccessor(
            data: meshData.positions.map { $0 as Any },
            componentType: 5126,  // Float
            type: "VEC3",
            byteLength: meshData.positions.count * 4
        )

        // Add normal accessor
        let normalIndex = addAccessor(
            data: meshData.normals.map { $0 as Any },
            componentType: 5126,  // Float
            type: "VEC3",
            byteLength: meshData.normals.count * 4
        )

        // Add texcoord accessor
        let texcoordIndex = addAccessor(
            data: meshData.texcoords.map { $0 as Any },
            componentType: 5126,  // Float
            type: "VEC2",
            byteLength: meshData.texcoords.count * 4
        )

        // Add indices accessor
        let indicesIndex = addAccessor(
            data: meshData.indices.map { $0 as Any },
            componentType: 5123,  // Unsigned short
            type: "SCALAR",
            byteLength: meshData.indices.count * 2
        )

        // Build mesh with correct accessor indices
        let mesh = buildHumanoidMeshWithAccessors(
            positionAccessor: positionIndex,
            normalAccessor: normalIndex,
            texcoordAccessor: texcoordIndex,
            indicesAccessor: indicesIndex
        )

        // Create buffer
        let buffer: [String: Any] = [
            "byteLength": allBufferData.count
        ]

        // Create glTF document using dictionary then encode/decode
        var documentDict: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "VRMBuilder (GameOfMods)"
            ],
            "scene": 0,
            "scenes": [
                [
                    "name": "Scene",
                    "nodes": [0]  // Root is hips
                ]
            ],
            "extensionsUsed": ["VRMC_vrm"]
        ]

        if let copyright = meta.copyrightInformation {
            var asset = documentDict["asset"] as! [String: Any]
            asset["copyright"] = copyright
            documentDict["asset"] = asset
        }

        // Encode nodes as JSON-compatible
        let nodesData = try! JSONEncoder().encode(nodes)
        let nodesArray = try! JSONSerialization.jsonObject(with: nodesData) as! [[String: Any]]
        documentDict["nodes"] = nodesArray

        // Encode meshes
        let meshesData = try! JSONEncoder().encode([mesh])
        let meshesArray = try! JSONSerialization.jsonObject(with: meshesData) as! [[String: Any]]
        documentDict["meshes"] = meshesArray

        // Encode materials
        let materialsData = try! JSONEncoder().encode([material])
        let materialsArray =
            try! JSONSerialization.jsonObject(with: materialsData) as! [[String: Any]]
        documentDict["materials"] = materialsArray

        // Add buffer data to document
        documentDict["accessors"] = accessors
        documentDict["bufferViews"] = bufferViews
        documentDict["buffers"] = [buffer]

        // Decode back to GLTFDocument
        let jsonData = try! JSONSerialization.data(withJSONObject: documentDict)
        var document = try! JSONDecoder().decode(GLTFDocument.self, from: jsonData)

        // Store the binary buffer data so it can be serialized
        document.binaryBufferData = allBufferData

        return document
    }

    private func buildNodes() -> [GLTFNode] {
        let skeleton = skeletonPreset.createSkeleton()
        var nodes: [GLTFNode] = []

        // Apply height morph to skeleton if specified
        let heightScale = morphValues["height"] ?? 1.0
        let shoulderScale = morphValues["shoulder_width"] ?? 1.0

        for boneData in skeleton.bones {
            var translation = boneData.translation
            var scale: [Float] = [1.0, 1.0, 1.0]

            // Apply morphs
            if boneData.bone == .hips {
                translation[1] *= heightScale  // Scale Y position
            }

            if boneData.bone == .leftShoulder || boneData.bone == .rightShoulder {
                scale[0] *= shoulderScale
            }

            // Build node as dictionary then encode/decode
            var nodeDict: [String: Any] = [
                "name": boneData.bone.rawValue,
                "translation": translation,
                "rotation": [0, 0, 0, 1],  // Identity quaternion
                "scale": scale
            ]

            if let children = boneData.children {
                nodeDict["children"] = children
            }

            if boneData.bone == .hips {
                nodeDict["mesh"] = 0  // Attach mesh to hips
            }

            let jsonData = try! JSONSerialization.data(withJSONObject: nodeDict)
            let node = try! JSONDecoder().decode(GLTFNode.self, from: jsonData)

            nodes.append(node)
        }

        return nodes
    }

    private func buildHumanoid() throws -> VRMHumanoid {
        let humanoid = VRMHumanoid()
        let skeleton = skeletonPreset.createSkeleton()

        // Map bones to node indices
        for (index, boneData) in skeleton.bones.enumerated() {
            humanoid.humanBones[boneData.bone] = VRMHumanoid.VRMHumanBone(node: index)
        }

        // Validate required bones
        try humanoid.validate()

        return humanoid
    }

    private func buildExpressions() -> VRMExpressions {
        let vrmExpressions = VRMExpressions()

        // Add requested expressions (placeholder - no morph targets yet)
        for preset in expressions {
            let expression = VRMExpression(name: preset.rawValue, preset: preset)
            vrmExpressions.preset[preset] = expression
        }

        return vrmExpressions
    }

    private func buildHumanoidMesh() -> GLTFMesh {
        // Create a humanoid mesh with actual geometry
        let meshDict: [String: Any] = [
            "name": "Body",
            "primitives": [
                [
                    "attributes": [
                        "POSITION": 0,
                        "NORMAL": 1,
                        "TEXCOORD_0": 2
                    ],
                    "indices": 3,
                    "material": 0,
                    "mode": 4  // TRIANGLES
                ]
            ]
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: meshDict)
        let mesh = try! JSONDecoder().decode(GLTFMesh.self, from: jsonData)
        return mesh
    }

    private func buildHumanoidMeshWithAccessors(
        positionAccessor: Int, normalAccessor: Int, texcoordAccessor: Int, indicesAccessor: Int
    ) -> GLTFMesh {
        // Create a humanoid mesh with specific accessor indices
        let meshDict: [String: Any] = [
            "name": "Body",
            "primitives": [
                [
                    "attributes": [
                        "POSITION": positionAccessor,
                        "NORMAL": normalAccessor,
                        "TEXCOORD_0": texcoordAccessor
                    ],
                    "indices": indicesAccessor,
                    "material": 0,
                    "mode": 4  // TRIANGLES
                ]
            ]
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: meshDict)
        let mesh = try! JSONDecoder().decode(GLTFMesh.self, from: jsonData)
        return mesh
    }

    private func buildMaterial() -> GLTFMaterial {
        // Create MToon-style material
        let skinColor = interpolateSkinTone(skinTone)

        // Build material as dictionary then encode/decode
        // This works around the Codable-only initializer
        let materialDict: [String: Any] = [
            "name": "Skin",
            "pbrMetallicRoughness": [
                "baseColorFactor": [skinColor.x, skinColor.y, skinColor.z, 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": 1.0
            ],
            "alphaMode": "OPAQUE",
            "doubleSided": false
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: materialDict)
        let material = try! JSONDecoder().decode(GLTFMaterial.self, from: jsonData)
        return material
    }

    private func interpolateSkinTone(_ value: Float) -> SIMD3<Float> {
        let lightSkin = SIMD3<Float>(0.95, 0.85, 0.75)
        let darkSkin = SIMD3<Float>(0.35, 0.25, 0.20)
        let t = SIMD3<Float>(repeating: value)
        return lightSkin * (SIMD3<Float>(1, 1, 1) - t) + darkSkin * t
    }
}

// MARK: - Helper Extensions

extension VRMMeta {
    static func `default`() -> VRMMeta {
        var meta = VRMMeta(licenseUrl: "")
        meta.name = "VRMBuilder Character"
        meta.version = "1.0"
        meta.authors = ["VRMBuilder"]
        meta.copyrightInformation = "Generated by VRMBuilder"
        return meta
    }
}
