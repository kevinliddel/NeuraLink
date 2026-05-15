//
// GLTFDocumentBuilder.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation

/// Builder for creating glTF documents programmatically
public class GLTFDocumentBuilder {

    private var asset: GLTFAsset?
    private var scenes: [GLTFScene] = []
    private var nodes: [GLTFNode] = []
    private var meshes: [GLTFMesh] = []
    private var materials: [GLTFMaterial] = []
    private var textures: [GLTFTexture] = []
    private var images: [GLTFImage] = []
    private var samplers: [GLTFSampler] = []
    private var buffers: [GLTFBuffer] = []
    private var bufferViews: [GLTFBufferView] = []
    private var accessors: [GLTFAccessor] = []
    private var skins: [GLTFSkin] = []
    private var animations: [GLTFAnimation] = []
    private var extensions: [String: Any] = [:]
    private var extensionsUsed: [String] = []
    private var extensionsRequired: [String] = []
    private var defaultScene: Int = 0

    public init() {}

    // MARK: - Configuration

    @discardableResult
    public func setAsset(_ asset: GLTFAsset) -> GLTFDocumentBuilder {
        self.asset = asset
        return self
    }

    @discardableResult
    public func addScene(_ scene: GLTFScene) -> GLTFDocumentBuilder {
        scenes.append(scene)
        return self
    }

    @discardableResult
    public func setNodes(_ nodes: [GLTFNode]) -> GLTFDocumentBuilder {
        self.nodes = nodes
        return self
    }

    @discardableResult
    public func setMeshes(_ meshes: [GLTFMesh]) -> GLTFDocumentBuilder {
        self.meshes = meshes
        return self
    }

    @discardableResult
    public func setMaterials(_ materials: [GLTFMaterial]) -> GLTFDocumentBuilder {
        self.materials = materials
        return self
    }

    @discardableResult
    public func setTextures(_ textures: [GLTFTexture]) -> GLTFDocumentBuilder {
        self.textures = textures
        return self
    }

    @discardableResult
    public func setImages(_ images: [GLTFImage]) -> GLTFDocumentBuilder {
        self.images = images
        return self
    }

    @discardableResult
    public func setSamplers(_ samplers: [GLTFSampler]) -> GLTFDocumentBuilder {
        self.samplers = samplers
        return self
    }

    @discardableResult
    public func setBuffers(_ buffers: [GLTFBuffer]) -> GLTFDocumentBuilder {
        self.buffers = buffers
        return self
    }

    @discardableResult
    public func setBufferViews(_ bufferViews: [GLTFBufferView]) -> GLTFDocumentBuilder {
        self.bufferViews = bufferViews
        return self
    }

    @discardableResult
    public func setAccessors(_ accessors: [GLTFAccessor]) -> GLTFDocumentBuilder {
        self.accessors = accessors
        return self
    }

    @discardableResult
    public func setSkins(_ skins: [GLTFSkin]) -> GLTFDocumentBuilder {
        self.skins = skins
        return self
    }

    @discardableResult
    public func setAnimations(_ animations: [GLTFAnimation]) -> GLTFDocumentBuilder {
        self.animations = animations
        return self
    }

    @discardableResult
    public func addExtension(name: String, data: Any) -> GLTFDocumentBuilder {
        extensions[name] = data
        return self
    }

    @discardableResult
    public func setExtensionsUsed(_ extensions: [String]) -> GLTFDocumentBuilder {
        self.extensionsUsed = extensions
        return self
    }

    @discardableResult
    public func setExtensionsRequired(_ extensions: [String]) -> GLTFDocumentBuilder {
        self.extensionsRequired = extensions
        return self
    }

    @discardableResult
    public func setDefaultScene(_ index: Int) -> GLTFDocumentBuilder {
        self.defaultScene = index
        return self
    }

    // MARK: - Build

    public func build() throws -> GLTFDocument {
        guard let asset = asset else {
            throw BuilderError.missingAsset
        }

        // Create a custom document since GLTFDocument's init is Codable
        // We'll use reflection to build it
        let document = MinimalGLTFDocument(
            asset: asset,
            scene: scenes.isEmpty ? nil : defaultScene,
            scenes: scenes.isEmpty ? nil : scenes,
            nodes: nodes.isEmpty ? nil : nodes,
            meshes: meshes.isEmpty ? nil : meshes,
            materials: materials.isEmpty ? nil : materials,
            textures: textures.isEmpty ? nil : textures,
            images: images.isEmpty ? nil : images,
            samplers: samplers.isEmpty ? nil : samplers,
            buffers: buffers.isEmpty ? nil : buffers,
            bufferViews: bufferViews.isEmpty ? nil : bufferViews,
            accessors: accessors.isEmpty ? nil : accessors,
            skins: skins.isEmpty ? nil : skins,
            animations: animations.isEmpty ? nil : animations,
            extensions: extensions.isEmpty ? nil : extensions,
            extensionsUsed: extensionsUsed.isEmpty ? nil : extensionsUsed,
            extensionsRequired: extensionsRequired.isEmpty ? nil : extensionsRequired
        )

        return document.toGLTFDocument()
    }

    enum BuilderError: Error {
        case missingAsset
    }
}

// MARK: - Minimal Document Helper

/// Helper struct for building glTF documents
private struct MinimalGLTFDocument {
    let asset: GLTFAsset
    let scene: Int?
    let scenes: [GLTFScene]?
    let nodes: [GLTFNode]?
    let meshes: [GLTFMesh]?
    let materials: [GLTFMaterial]?
    let textures: [GLTFTexture]?
    let images: [GLTFImage]?
    let samplers: [GLTFSampler]?
    let buffers: [GLTFBuffer]?
    let bufferViews: [GLTFBufferView]?
    let accessors: [GLTFAccessor]?
    let skins: [GLTFSkin]?
    let animations: [GLTFAnimation]?
    let extensions: [String: Any]?
    let extensionsUsed: [String]?
    let extensionsRequired: [String]?

    func toGLTFDocument() -> GLTFDocument {
        // Encode to JSON, then decode back to GLTFDocument
        // This is a workaround since GLTFDocument uses Codable init

        let dict: [String: Any] = [
            "asset": encodeAsset(asset),
            "scene": scene as Any,
            "scenes": scenes?.map(encodeScene) as Any,
            "nodes": nodes?.map(encodeNode) as Any,
            "meshes": meshes?.map(encodeMesh) as Any,
            "materials": materials?.map(encodeMaterial) as Any,
            "textures": textures as Any,
            "images": images as Any,
            "samplers": samplers as Any,
            "buffers": buffers as Any,
            "bufferViews": bufferViews as Any,
            "accessors": accessors as Any,
            "skins": skins as Any,
            "animations": animations as Any,
            "extensions": extensions as Any,
            "extensionsUsed": extensionsUsed as Any,
            "extensionsRequired": extensionsRequired as Any
        ].compactMapValues { $0 }

        let jsonData = try! JSONSerialization.data(withJSONObject: dict)
        let document = try! JSONDecoder().decode(GLTFDocument.self, from: jsonData)
        return document
    }

    private func encodeAsset(_ asset: GLTFAsset) -> [String: Any] {
        var dict: [String: Any] = ["version": asset.version]
        if let gen = asset.generator { dict["generator"] = gen }
        if let copy = asset.copyright { dict["copyright"] = copy }
        if let min = asset.minVersion { dict["minVersion"] = min }
        return dict
    }

    private func encodeScene(_ scene: GLTFScene) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let name = scene.name { dict["name"] = name }
        if let nodes = scene.nodes { dict["nodes"] = nodes }
        return dict
    }

    private func encodeNode(_ node: GLTFNode) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let name = node.name { dict["name"] = name }
        if let children = node.children { dict["children"] = children }
        if let matrix = node.matrix { dict["matrix"] = matrix }
        if let translation = node.translation { dict["translation"] = translation }
        if let rotation = node.rotation { dict["rotation"] = rotation }
        if let scale = node.scale { dict["scale"] = scale }
        if let mesh = node.mesh { dict["mesh"] = mesh }
        if let skin = node.skin { dict["skin"] = skin }
        if let weights = node.weights { dict["weights"] = weights }
        return dict
    }

    private func encodeMesh(_ mesh: GLTFMesh) -> [String: Any] {
        var dict: [String: Any] = [
            "primitives": mesh.primitives.map(encodePrimitive)
        ]
        if let name = mesh.name { dict["name"] = name }
        if let weights = mesh.weights { dict["weights"] = weights }
        return dict
    }

    private func encodePrimitive(_ primitive: GLTFPrimitive) -> [String: Any] {
        var dict: [String: Any] = [
            "attributes": primitive.attributes
        ]
        if let indices = primitive.indices { dict["indices"] = indices }
        if let material = primitive.material { dict["material"] = material }
        if let mode = primitive.mode { dict["mode"] = mode }
        return dict
    }

    private func encodeMaterial(_ material: GLTFMaterial) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let name = material.name { dict["name"] = name }
        if let pbr = material.pbrMetallicRoughness {
            dict["pbrMetallicRoughness"] = encodePBR(pbr)
        }
        if let alphaMode = material.alphaMode { dict["alphaMode"] = alphaMode }
        dict["doubleSided"] = material.doubleSided
        return dict
    }

    private func encodePBR(_ pbr: GLTFPBRMetallicRoughness) -> [String: Any] {
        var dict: [String: Any] = [:]
        if let baseColorFactor = pbr.baseColorFactor {
            dict["baseColorFactor"] = baseColorFactor
        }
        if let metallicFactor = pbr.metallicFactor {
            dict["metallicFactor"] = metallicFactor
        }
        if let roughnessFactor = pbr.roughnessFactor {
            dict["roughnessFactor"] = roughnessFactor
        }
        return dict
    }
}
