//
// GLTFParser.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation

// MARK: - GLTF Document Structure
public struct GLTFDocument: Codable {
    public let asset: GLTFAsset
    public let scene: Int?
    public let scenes: [GLTFScene]?
    public let nodes: [GLTFNode]?
    public let meshes: [GLTFMesh]?
    public let materials: [GLTFMaterial]?
    public let textures: [GLTFTexture]?
    public let images: [GLTFImage]?
    public let samplers: [GLTFSampler]?
    public let buffers: [GLTFBuffer]?
    public let bufferViews: [GLTFBufferView]?
    public let accessors: [GLTFAccessor]?
    public let skins: [GLTFSkin]?
    public let animations: [GLTFAnimation]?
    public let extensions: [String: Any]?
    public let extensionsUsed: [String]?
    public let extensionsRequired: [String]?

    public var binaryBufferData: Data?

    enum CodingKeys: String, CodingKey {
        case asset, scene, scenes, nodes, meshes, materials
        case textures, images, samplers, buffers, bufferViews
        case accessors, skins, animations, extensions
        case extensionsUsed, extensionsRequired
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asset = try container.decode(GLTFAsset.self, forKey: .asset)
        scene = try container.decodeIfPresent(Int.self, forKey: .scene)
        scenes = try container.decodeIfPresent([GLTFScene].self, forKey: .scenes)
        nodes = try container.decodeIfPresent([GLTFNode].self, forKey: .nodes)
        meshes = try container.decodeIfPresent([GLTFMesh].self, forKey: .meshes)
        materials = try container.decodeIfPresent([GLTFMaterial].self, forKey: .materials)
        textures = try container.decodeIfPresent([GLTFTexture].self, forKey: .textures)
        images = try container.decodeIfPresent([GLTFImage].self, forKey: .images)
        samplers = try container.decodeIfPresent([GLTFSampler].self, forKey: .samplers)
        buffers = try container.decodeIfPresent([GLTFBuffer].self, forKey: .buffers)
        bufferViews = try container.decodeIfPresent([GLTFBufferView].self, forKey: .bufferViews)
        accessors = try container.decodeIfPresent([GLTFAccessor].self, forKey: .accessors)
        skins = try container.decodeIfPresent([GLTFSkin].self, forKey: .skins)
        animations = try container.decodeIfPresent([GLTFAnimation].self, forKey: .animations)
        extensionsUsed = try container.decodeIfPresent([String].self, forKey: .extensionsUsed)
        extensionsRequired = try container.decodeIfPresent(
            [String].self, forKey: .extensionsRequired)

        if container.contains(.extensions) {
            let extensionsDict = try container.decodeIfPresent(
                [String: AnyCodable].self, forKey: .extensions)
            extensions = extensionsDict?.mapValues { $0.value }
        } else {
            extensions = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asset, forKey: .asset)
        try container.encodeIfPresent(scene, forKey: .scene)
        try container.encodeIfPresent(scenes, forKey: .scenes)
        try container.encodeIfPresent(nodes, forKey: .nodes)
        try container.encodeIfPresent(meshes, forKey: .meshes)
        try container.encodeIfPresent(materials, forKey: .materials)
        try container.encodeIfPresent(textures, forKey: .textures)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encodeIfPresent(samplers, forKey: .samplers)
        try container.encodeIfPresent(buffers, forKey: .buffers)
        try container.encodeIfPresent(bufferViews, forKey: .bufferViews)
        try container.encodeIfPresent(accessors, forKey: .accessors)
        try container.encodeIfPresent(skins, forKey: .skins)
        try container.encodeIfPresent(animations, forKey: .animations)
        try container.encodeIfPresent(extensionsUsed, forKey: .extensionsUsed)
        try container.encodeIfPresent(extensionsRequired, forKey: .extensionsRequired)
    }
}

// MARK: - GLTF Components
public struct GLTFAsset: Codable {
    public let version: String
    public let generator: String?
    public let copyright: String?
    public let minVersion: String?
}
public struct GLTFScene: Codable {
    public let name: String?
    public let nodes: [Int]?
}
public struct GLTFNode: Codable {
    public let name: String?
    public let children: [Int]?
    public let matrix: [Float]?
    public let translation: [Float]?
    public let rotation: [Float]?
    public let scale: [Float]?
    public let mesh: Int?
    public let skin: Int?
    public let weights: [Float]?
    public let extensions: [String: AnyCodable]?
}
public struct GLTFMesh: Codable {
    public let name: String?
    public let primitives: [GLTFPrimitive]
    public let weights: [Float]?
    public let extras: GLTFMeshExtras?
}
public struct GLTFMeshExtras: Codable {
    public let targetNames: [String]?
}
public struct GLTFPrimitive: Codable {
    public let attributes: [String: Int]
    public let indices: Int?
    public let material: Int?
    public let mode: Int?
    public let targets: [GLTFMorphTarget]?
}

public struct GLTFMorphTarget: Codable {
    public let position: Int?
    public let normal: Int?
    public let tangent: Int?
    public let extra: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case position = "POSITION"
        case normal = "NORMAL"
        case tangent = "TANGENT"
        case extra
    }
}
public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try decoding in order of most common types
        if container.decodeNil() {
            value = NSNull()
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let floatValue = try? container.decode(Float.self) {
            value = floatValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let dictValue = try? container.decode([String: AnyCodable].self) {
            value = dictValue.mapValues { $0.value }
        } else if let arrayValue = try? container.decode([AnyCodable].self) {
            value = arrayValue.map { $0.value }
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let floatValue as Float:
            try container.encode(floatValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let dictValue as [String: Any]:
            let encodableDict = dictValue.mapValues { AnyCodable($0) }
            try container.encode(encodableDict)
        case let arrayValue as [Any]:
            let encodableArray = arrayValue.map { AnyCodable($0) }
            try container.encode(encodableArray)
        default:
            try container.encodeNil()
        }
    }
}
public struct GLTFMaterial: Codable {
    public let name: String?
    public let pbrMetallicRoughness: GLTFPBRMetallicRoughness?
    public let normalTexture: GLTFNormalTextureInfo?
    public let occlusionTexture: GLTFOcclusionTextureInfo?
    public let emissiveTexture: GLTFTextureInfo?
    public let emissiveFactor: [Float]?
    public let alphaMode: String?
    public let alphaCutoff: Float?
    public let doubleSided: Bool?
    public let extensions: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case name, pbrMetallicRoughness, normalTexture
        case occlusionTexture, emissiveTexture, emissiveFactor
        case alphaMode, alphaCutoff, doubleSided, extensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        pbrMetallicRoughness = try container.decodeIfPresent(
            GLTFPBRMetallicRoughness.self, forKey: .pbrMetallicRoughness)
        normalTexture = try container.decodeIfPresent(
            GLTFNormalTextureInfo.self, forKey: .normalTexture)
        occlusionTexture = try container.decodeIfPresent(
            GLTFOcclusionTextureInfo.self, forKey: .occlusionTexture)
        emissiveTexture = try container.decodeIfPresent(
            GLTFTextureInfo.self, forKey: .emissiveTexture)
        emissiveFactor = try container.decodeIfPresent([Float].self, forKey: .emissiveFactor)
        alphaMode = try container.decodeIfPresent(String.self, forKey: .alphaMode)
        alphaCutoff = try container.decodeIfPresent(Float.self, forKey: .alphaCutoff)
        doubleSided = try container.decodeIfPresent(Bool.self, forKey: .doubleSided)
        if container.contains(.extensions) {
            if let extWrapper = try? container.decode(
                [String: AnyCodable].self, forKey: .extensions) {
                extensions = extWrapper.mapValues { $0.value }
            } else {
                extensions = nil
            }
        } else {
            extensions = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(pbrMetallicRoughness, forKey: .pbrMetallicRoughness)
        try container.encodeIfPresent(normalTexture, forKey: .normalTexture)
        try container.encodeIfPresent(occlusionTexture, forKey: .occlusionTexture)
        try container.encodeIfPresent(emissiveTexture, forKey: .emissiveTexture)
        try container.encodeIfPresent(emissiveFactor, forKey: .emissiveFactor)
        try container.encodeIfPresent(alphaMode, forKey: .alphaMode)
        try container.encodeIfPresent(alphaCutoff, forKey: .alphaCutoff)
        try container.encodeIfPresent(doubleSided, forKey: .doubleSided)
    }
}
public struct GLTFPBRMetallicRoughness: Codable {
    public let baseColorFactor: [Float]?
    public let baseColorTexture: GLTFTextureInfo?
    public let metallicFactor: Float?
    public let roughnessFactor: Float?
    public let metallicRoughnessTexture: GLTFTextureInfo?
}
public struct GLTFTextureInfo: Codable {
    public let index: Int
    public let texCoord: Int?
}
public struct GLTFNormalTextureInfo: Codable {
    public let index: Int
    public let texCoord: Int?
    public let scale: Float?
}
public struct GLTFOcclusionTextureInfo: Codable {
    public let index: Int
    public let texCoord: Int?
    public let strength: Float?
}
public struct GLTFTexture: Codable {
    public let sampler: Int?
    public let source: Int?
    public let name: String?
}
public struct GLTFImage: Codable {
    public let uri: String?
    public let mimeType: String?
    public let bufferView: Int?
    public let name: String?
}
public struct GLTFSampler: Codable {
    public let magFilter: Int?
    public let minFilter: Int?
    public let wrapS: Int?
    public let wrapT: Int?
}
public struct GLTFBuffer: Codable {
    public let byteLength: Int
    public let uri: String?
    public let name: String?
}
public struct GLTFBufferView: Codable {
    public let buffer: Int
    public let byteOffset: Int?
    public let byteLength: Int
    public let byteStride: Int?
    public let target: Int?
    public let name: String?
}
public struct GLTFAccessor: Codable {
    public let bufferView: Int?
    public let byteOffset: Int?
    public let componentType: Int
    public let count: Int
    public let type: String
    public let max: [Float]?
    public let min: [Float]?
    public let normalized: Bool?
    public let sparse: GLTFSparse?
    public let name: String?
}
public struct GLTFSparse: Codable {
    public let count: Int
    public let indices: GLTFSparseIndices
    public let values: GLTFSparseValues
}
public struct GLTFSparseIndices: Codable {
    public let bufferView: Int
    public let byteOffset: Int?
    public let componentType: Int
}
public struct GLTFSparseValues: Codable {
    public let bufferView: Int
    public let byteOffset: Int?
}
public struct GLTFSkin: Codable {
    public let inverseBindMatrices: Int?
    public let skeleton: Int?
    public let joints: [Int]
    public let name: String?
}
public struct GLTFAnimation: Codable {
    public let channels: [GLTFAnimationChannel]
    public let samplers: [GLTFAnimationSampler]
    public let name: String?
}
public struct GLTFAnimationChannel: Codable {
    public let sampler: Int
    public let target: GLTFAnimationTarget
}
public struct GLTFAnimationTarget: Codable {
    public let node: Int?
    public let path: String
}
public struct GLTFAnimationSampler: Codable {
    public let input: Int
    public let interpolation: String?
    public let output: Int
}

// MARK: - GLB Parser
public class GLTFParser {
    public private(set) var binaryChunk: Data?

    public init() {}

    public func parse(data: Data, filePath: String? = nil) throws -> (
        document: GLTFDocument, binaryData: Data?
    ) {
        // GLB Header - ensure we have at least 12 bytes for header
        guard data.count >= 12 else {
            throw VRMError.invalidGLBFormat(
                reason:
                    "File is too small (\(data.count) bytes). GLB files require at least 12 bytes for the header.",
                filePath: filePath
            )
        }

        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x4654_6C67 else {  // "glTF" in little-endian
            throw VRMError.invalidGLBFormat(
                reason:
                    "Invalid magic number 0x\(String(format: "%08X", magic)). Expected 0x46546C67 ('glTF').",
                filePath: filePath
            )
        }

        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard version == 2 else {
            throw VRMError.unsupportedVersion(
                version: "GLB \(version)",
                supported: ["GLB 2"],
                filePath: filePath
            )
        }

        // let length = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }

        // Parse chunks
        var offset = 12
        var jsonChunk: Data?

        while offset < data.count {
            // Ensure we have at least 8 bytes for chunk header
            guard offset + 8 <= data.count else {
                break
            }

            let chunkLength = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            let chunkType = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
            }

            // Validate chunk data range
            let chunkStart = offset + 8
            let chunkEnd = chunkStart + Int(chunkLength)
            guard chunkEnd <= data.count else {
                break
            }

            let chunkData = data.subdata(in: chunkStart..<chunkEnd)

            if chunkType == 0x4E4F_534A {  // "JSON"
                jsonChunk = chunkData
            } else if chunkType == 0x004E_4942 {  // "BIN\0"
                binaryChunk = chunkData
            }

            offset += 8 + Int(chunkLength)
        }

        guard let jsonData = jsonChunk else {
            throw VRMError.invalidJSON(
                context: "Missing JSON chunk in GLB file",
                underlyingError: nil,
                filePath: filePath
            )
        }

        // Parse JSON
        let decoder = JSONDecoder()
        do {
            let document = try decoder.decode(GLTFDocument.self, from: jsonData)
            return (document, self.binaryChunk)
        } catch {
            throw VRMError.invalidJSON(
                context: "Failed to decode glTF JSON structure",
                underlyingError: error.localizedDescription,
                filePath: filePath
            )
        }
    }
}

// MARK: - JSON+Any Extension
extension JSONDecoder {
    func decode(_ type: [String: Any].Type, from data: Data, filePath: String? = nil) throws
        -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = json as? [String: Any] else {
            let jsonTypeName = String(describing: Swift.type(of: json))
            throw VRMError.invalidJSON(
                context: "JSON root is not a dictionary object",
                underlyingError: "Expected dictionary, got \(jsonTypeName)",
                filePath: filePath
            )
        }
        return dict
    }
}
