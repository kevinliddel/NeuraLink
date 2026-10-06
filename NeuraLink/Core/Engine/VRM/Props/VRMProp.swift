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

import CoreGraphics
import Foundation
import ImageIO
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
    /// Uniform size multiplier on top of the file's own scale: 1 is life
    /// size, which anime-proportioned hands cannot quite close around.
    public var scale: Float

    public init(translation: SIMD3<Float>, rotation: simd_quatf, scale: Float = 1) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    func resolved(forVRM0 isVRM0: Bool) -> VRMPropGrip {
        guard isVRM0 else { return self }
        let yawInverse = VRMModel.vrmVersionYaw.inverse
        return VRMPropGrip(
            translation: yawInverse.act(translation), rotation: simd_normalize(yawInverse * rotation), scale: scale)
    }
}

/// Decodes one of a prop's images into a capped, mipmapped texture. Off
/// the main actor: the project's default isolation is MainActor, so the
/// glTF loaders (and anything else unannotated) run there even from a
/// detached task — and tens of megabytes of PNG decode on the main thread
/// at launch would stall the loading screen. Pure CoreGraphics + Metal, no
/// shared state.
nonisolated enum VRMPropTextureDecoder {

    @concurrent
    static func decode(_ data: Data, sRGB: Bool, maxSize: Int, device: MTLDevice) async -> MTLTexture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let scale = min(1.0, Double(maxSize) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sRGB ? .rgba8Unorm_srgb : .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        pixels.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            }
        }
        if texture.mipmapLevelCount > 1, let queue = device.makeCommandQueue(),
            let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }
}

/// Loads a plain glTF binary into a `VRMProp`. `VRMModel.load` refuses a
/// file without a VRM extension, so this drives the lower-level loaders
/// directly. Textures are capped — a 15 cm object never needs the 4096²
/// maps a Sketchfab export ships — and mipmapped, since the prop covers a
/// hundred-odd pixels on screen; their decode runs off the main actor
/// (`VRMPropTextureDecoder`), the small geometry/material part on it.
public enum VRMPropLoader {

    public static func load(url: URL, device: MTLDevice, maxTextureSize: Int = 1024) async throws -> VRMProp {
        let data = try Data(contentsOf: url)
        let (document, binary) = try GLTFParser().parse(data: data)
        let baseURL = url.deletingPathExtension().deletingLastPathComponent()
        let bufferLoader = BufferLoader(document: document, binaryData: binary, baseURL: baseURL)
        let name = url.deletingPathExtension().lastPathComponent

        let textures = try await loadTextures(document: document, binary: binary, device: device, maxSize: maxTextureSize)
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
    private static func loadTextures(document: GLTFDocument, binary: Data?, device: MTLDevice, maxSize: Int) async throws -> [VRMTexture] {
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
            if colourIndices.contains(index) || linearIndices.contains(index),
                let bytes = imageBytes(textureIndex: index, document: document, binary: binary) {
                texture.mtlTexture = await VRMPropTextureDecoder.decode(
                    bytes, sRGB: colourIndices.contains(index), maxSize: maxSize, device: device)
            }
            textures.append(texture)
        }
        return textures
    }

    /// The encoded image behind a texture: a slice of the GLB's binary chunk
    /// (a prop is a self-contained .glb; external image URIs are not used).
    private static func imageBytes(textureIndex: Int, document: GLTFDocument, binary: Data?) -> Data? {
        guard let sourceIndex = document.textures?[safe: textureIndex]?.source,
            let image = document.images?[safe: sourceIndex],
            let viewIndex = image.bufferView,
            let view = document.bufferViews?[safe: viewIndex],
            let binary
        else { return nil }
        let start = view.byteOffset ?? 0
        guard start >= 0, start + view.byteLength <= binary.count else { return nil }
        return binary.subdata(in: start..<(start + view.byteLength))
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
