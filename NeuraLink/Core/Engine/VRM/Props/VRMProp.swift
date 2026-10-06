//
//  VRMProp.swift
//  NeuraLink
//
//  A rigid hand-held object (the companion's phone) loaded from a plain
//  glTF binary. Unlike a part graft it is not skinned: attached to a model
//  (VRMModel+Props.swift) it becomes one runtime node under a humanoid
//  bone, drawn with that node's world matrix by the renderer's rigid path
//  and the character's shadow pass. The asset is device-wide — one phone
//  serves every character — so GPU buffers are shared between attachments.
//
//  Created by Dedicatus on 06/10/2026.
//

import Foundation
import Metal
import simd

public enum VRMPropError: Error, LocalizedError {
    case noMesh
    case missingBone(VRMHumanoidBone)

    public var errorDescription: String? {
        switch self {
        case .noMesh: return "The prop file contains no mesh."
        case .missingBone(let bone): return "The model has no \(bone.rawValue) bone to hold the prop."
        }
    }
}

/// GPU-side asset: a plain GLB's meshes, materials and textures, plus the
/// transform its scene graph puts each mesh in.
public final class VRMProp {
    /// One mesh node of the file with the node chain above it composed into
    /// a single transform. mobile_phone.glb carries its 0.01 cm→m scale and a
    /// −90° X turn in that chain (long axis +Y, screen +Z afterwards); the raw
    /// vertices stay in file units and the chain lives on the attached node.
    public struct Part {
        public let mesh: VRMMesh
        let chain: RestTransform
    }

    public let name: String
    public let parts: [Part]
    public let materials: [VRMMaterial]
    public let textures: [VRMTexture]
    /// Axis-aligned extent in metres with the chain applied — the size the
    /// prop has in a hand.
    public let extent: SIMD3<Float>

    init(name: String, parts: [Part], materials: [VRMMaterial], textures: [VRMTexture], extent: SIMD3<Float>) {
        self.name = name
        self.parts = parts
        self.materials = materials
        self.textures = textures
        self.extent = extent
    }
}

/// Where a prop sits in a hand: hand-local translation (metres) and
/// rotation, authored in the VRM 1.0 hand frame (T-pose: right-hand fingers
/// along −X, thumb +Z, palm facing −Y). A VRM 0.x rig lays its hands out
/// yawed 180° in file space (the renderer yaws the whole model back), so
/// for it the grip is re-expressed in that frame: the hand frame turns by
/// the yaw while the prop's on-screen orientation stays the same, hence
/// yaw⁻¹ · grip — not the yaw·q·yaw⁻¹ conjugation grafted bone chains use,
/// where both ends of the chain turn.
public struct VRMPropGrip: Equatable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf

    public init(translation: SIMD3<Float>, rotation: simd_quatf) {
        self.translation = translation
        self.rotation = rotation
    }

    func resolved(forVRM0 isVRM0: Bool) -> VRMPropGrip {
        guard isVRM0 else { return self }
        let yawInverse = VRMModel.vrmVersionYaw.inverse
        return VRMPropGrip(translation: yawInverse.act(translation), rotation: simd_normalize(yawInverse * rotation))
    }
}

/// Loads a plain glTF binary into a `VRMProp`. `VRMModel.load` refuses a
/// file without a VRM extension, so this drives the lower-level loaders
/// directly. Textures are capped — a 15 cm object never needs the 4096²
/// maps a Sketchfab export ships — and mipmapped, since the prop covers a
/// hundred-odd pixels on screen.
public enum VRMPropLoader {

    public static func load(url: URL, device: MTLDevice, maxTextureSize: Int = 1024) async throws -> VRMProp {
        let data = try Data(contentsOf: url)
        let (document, binary) = try GLTFParser().parse(data: data)
        let baseURL = url.deletingLastPathComponent()
        let bufferLoader = BufferLoader(document: document, binaryData: binary, baseURL: baseURL)
        let textureLoader = TextureLoader(device: device, bufferLoader: bufferLoader, document: document, baseURL: baseURL)
        let name = url.deletingPathExtension().lastPathComponent

        let textures = try await loadTextures(document: document, loader: textureLoader, maxSize: maxTextureSize)
        let materials = (document.materials ?? []).map { gltfMaterial -> VRMMaterial in
            // Built as VRM 1.0 whatever the host is: under 0.x rules a BLEND
            // material would be promoted to the depth-writing path.
            let material = VRMMaterial(from: gltfMaterial, textures: textures, vrmVersion: .v1_0)
            material.preservesEmissive = true  // the screen glows
            return material
        }

        var parts: [VRMProp.Part] = []
        var extentMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var extentMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let sceneIndex = document.scene ?? 0
        var instances: [(meshIndex: Int, chain: RestTransform)] = []
        for nodeIndex in document.scenes?[safe: sceneIndex]?.nodes ?? [] {
            collectMeshInstances(nodeIndex: nodeIndex, parent: .identity, document: document, into: &instances)
        }
        for (meshIndex, chain) in instances {
            guard let gltfMesh = document.meshes?[safe: meshIndex] else { continue }
            let mesh = try await VRMMesh.load(from: gltfMesh, document: document, device: device, bufferLoader: bufferLoader)
            parts.append(.init(mesh: mesh, chain: chain))
            for primitive in mesh.primitives {
                let (low, high) = transformedBounds(of: primitive, chain: chain)
                extentMin = min(extentMin, low)
                extentMax = max(extentMax, high)
            }
        }
        guard !parts.isEmpty else { throw VRMPropError.noMesh }

        let extent = extentMax - extentMin
        nlLog(
            "[VRMProp] Loaded '\(name)': \(parts.count) part(s), \(materials.count) material(s), "
                + "\(textures.filter { $0.mtlTexture != nil }.count) texture(s) ≤\(maxTextureSize)px, "
                + String(format: "extent %.3f × %.3f × %.3f m", extent.x, extent.y, extent.z),
            level: .info)
        return VRMProp(name: name, parts: parts, materials: materials, textures: textures, extent: extent)
    }

    /// Only the maps the MToon path samples (base colour, normal, emissive);
    /// occlusion and metallic-roughness are never bound, so they stay on disk.
    /// Unused slots keep a placeholder so material indices line up.
    private static func loadTextures(document: GLTFDocument, loader: TextureLoader, maxSize: Int) async throws -> [VRMTexture] {
        var colourIndices = Set<Int>()
        var linearIndices = Set<Int>()
        for material in document.materials ?? [] {
            if let index = material.pbrMetallicRoughness?.baseColorTexture?.index { colourIndices.insert(index) }
            if let index = material.emissiveTexture?.index { colourIndices.insert(index) }
            if let index = material.normalTexture?.index { linearIndices.insert(index) }
        }
        var textures: [VRMTexture] = []
        for index in 0..<(document.textures?.count ?? 0) {
            let texture = VRMTexture(name: "texture_\(index)")
            if colourIndices.contains(index) || linearIndices.contains(index) {
                texture.mtlTexture = try await loader.loadTexture(
                    at: index, sRGB: colourIndices.contains(index), maxSize: maxSize, withMipmaps: true)
            }
            textures.append(texture)
        }
        return textures
    }

    private static func collectMeshInstances(
        nodeIndex: Int, parent: RestTransform, document: GLTFDocument,
        into result: inout [(meshIndex: Int, chain: RestTransform)]
    ) {
        guard let node = document.nodes?[safe: nodeIndex] else { return }
        let local = RestTransform(node: node)
        let world = RestTransform(
            rotation: simd_normalize(parent.rotation * local.rotation),
            translation: parent.translation + parent.rotation.act(parent.scale * local.translation),
            scale: parent.scale * local.scale)
        if let meshIndex = node.mesh { result.append((meshIndex, world)) }
        for child in node.children ?? [] {
            collectMeshInstances(nodeIndex: child, parent: world, document: document, into: &result)
        }
    }

    private static func transformedBounds(of primitive: VRMPrimitive, chain: RestTransform) -> (SIMD3<Float>, SIMD3<Float>) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        guard let buffer = primitive.vertexBuffer, primitive.vertexCount > 0 else { return (low, high) }
        let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
        for index in 0..<primitive.vertexCount {
            let position = chain.translation + chain.rotation.act(chain.scale * vertices[index].position)
            low = min(low, position)
            high = max(high, position)
        }
        return (low, high)
    }
}
