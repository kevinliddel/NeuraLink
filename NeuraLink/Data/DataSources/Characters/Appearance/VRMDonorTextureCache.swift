//
//  VRMDonorTextureCache.swift
//  NeuraLink
//
//  Cheap inventory of another model's parts ("donor") without loading it:
//  parse the GLB header, walk materials → slots, hash each slot's texture
//  bytes, read its UV footprint, and remember where the image bytes live in
//  the file. Nothing is decoded and no pixels are kept — a 20 MB VRM scans
//  in well under a second and the cached entry is a few KB, so the whole
//  parts library can be inventoried when the panel opens.
//
//  Painted-area masks (needed only to gate texture borrowing) and the image
//  bytes themselves (needed only to apply a texture) are produced on demand
//  from the recorded byte range.
//

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// One donor texture: identity, footprint, and where to find the bytes.
nonisolated public struct DonorSlotTexture: Sendable {
    public let slot: VRoidMaterialSlot
    /// glTF texture index in the donor document.
    public let textureIndex: Int
    public let mimeType: String?
    /// Absolute byte range of the encoded image inside the donor file.
    public let fileURL: URL
    public let imageByteRange: Range<Int>
    /// SHA-256 (hex) of the encoded texture bytes — identity for dedupe.
    public let imageHash: String
    /// Total triangle-index count of the donor primitives in this slot.
    public let indexCount: Int
    /// Atlas cells the donor's own geometry samples for this slot.
    public let uvCoverage: UVCoverageMask
    public let width: Int
    public let height: Int

    /// Encoded image bytes, read from the file (memory-mapped).
    public func loadImageData() -> Data? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
            imageByteRange.upperBound <= data.count
        else { return nil }
        return data.subdata(in: imageByteRange)
    }

    /// Cells a target may sample from this texture: everywhere the donor's
    /// own mesh samples (an iris texture is *meant* to be transparent
    /// outside the disc), plus painted texels — colour for body skin (drawn
    /// opaque), alpha for everything else.
    public func coverage(for slot: VRoidMaterialSlot, masks: DonorTextureMasks) -> UVCoverageMask {
        var mask = uvCoverage
        mask.formUnion(slot == .bodySkin ? masks.color : masks.alpha)
        return mask
    }
}

nonisolated public struct DonorTextureMasks: Sendable {
    public let alpha: UVCoverageMask
    public let color: UVCoverageMask
}

/// Everything usable from one donor file.
nonisolated public struct DonorScan: Sendable {
    public let slug: String
    public let url: URL
    public let slots: [VRoidMaterialSlot: DonorSlotTexture]
    /// glTF texture indices a part needs (base colour, shade, normal, matcap…).
    public let partTextureIndices: [AppearancePartKind: Set<Int>]

    /// Whether the donor has geometry for a graftable part. An outfit needs
    /// at least one garment: some VRoid models paint the clothes into the
    /// body-skin texture and keep only shoes as separate geometry, and
    /// there the outfit is "this model's skin + shoes".
    public func hasPart(_ kind: AppearancePartKind) -> Bool {
        switch kind {
        case .hair:
            return slots[.hair] != nil
        case .outfit:
            return [.tops, .onepiece, .bottoms, .shoes, .accessory].contains { slots[$0] != nil }
        case .tops:
            return slots[.tops] != nil || slots[.onepiece] != nil
        case .bottoms:
            return slots[.bottoms] != nil
        case .shoes:
            return slots[.shoes] != nil
        }
    }

    /// Identity of a graftable part: its textures + geometry size per slot.
    /// Two models wearing the same school uniform (different faces, hair,
    /// body) produce the same fingerprint, so the picker shows it once.
    /// Body skin is excluded from the outfit — it's the *model's*, not the
    /// outfit's.
    public func partFingerprint(_ kind: AppearancePartKind) -> String? {
        let relevant = kind.slots.subtracting(kind == .outfit ? [.bodySkin] : [])
        return fingerprint(forSlots: relevant)
    }

    /// Identity of a set of textures (face / eyes / skin categories).
    public func fingerprint(forSlots wanted: Set<VRoidMaterialSlot>) -> String? {
        let entries = wanted.sorted { $0.rawValue < $1.rawValue }.compactMap { slot -> String? in
            guard let texture = slots[slot] else { return nil }
            return "\(slot.rawValue):\(texture.imageHash):\(texture.indexCount)"
        }
        guard !entries.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(entries.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public actor VRMDonorTextureCache {
    public static let shared = VRMDonorTextureCache()

    private struct Key: Hashable {
        let path: String
        let modified: TimeInterval
        let size: Int
    }

    private var cache: [Key: DonorScan] = [:]
    private var inFlight: [Key: Task<DonorScan, Error>] = [:]
    private var masksByHash: [String: DonorTextureMasks] = [:]
    private var masksInFlight: [String: Task<DonorTextureMasks?, Never>] = [:]

    /// Scans are a few KB each; the whole library fits.
    private let maxEntries = 64

    public init() {}

    public func scan(url: URL, slug: String) async throws -> DonorScan {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let key = Key(
            path: url.path,
            modified: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: (attrs[.size] as? NSNumber)?.intValue ?? 0)
        if let hit = cache[key] { return hit }
        if let task = inFlight[key] { return try await task.value }

        let task = Task.detached(priority: .userInitiated) {
            try Self.performScan(url: url, slug: slug)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let scan = try await task.value
        if cache.count >= maxEntries, let victim = cache.keys.first { cache.removeValue(forKey: victim) }
        cache[key] = scan
        return scan
    }

    /// Painted-area masks for a donor texture, decoded once per image hash.
    public func coverageMasks(for texture: DonorSlotTexture) async -> DonorTextureMasks? {
        if let cached = masksByHash[texture.imageHash] { return cached }
        if let task = masksInFlight[texture.imageHash] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { () -> DonorTextureMasks? in
            guard let data = texture.loadImageData(),
                let masks = AppearanceTextureFactory.coverageMasks(imageData: data)
            else { return nil }
            return DonorTextureMasks(alpha: masks.alpha, color: masks.color)
        }
        masksInFlight[texture.imageHash] = task
        defer { masksInFlight[texture.imageHash] = nil }
        let masks = await task.value
        if let masks { masksByHash[texture.imageHash] = masks }
        return masks
    }

    public func invalidateAll() {
        cache.removeAll()
        masksByHash.removeAll()
    }

    // MARK: - Scan

    nonisolated private static func performScan(url: URL, slug: String) throws -> DonorScan {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parser = GLTFParser()
        let (document, binaryData) = try parser.parse(data: data, filePath: url.path)
        let bufferLoader = BufferLoader(document: document, binaryData: binaryData, baseURL: url.deletingLastPathComponent())
        let binaryChunkStart = glbBinaryChunkStart(data)

        // Older VRoid exports name every glTF material "VRM/MToon"; the real
        // names live in the VRM 0.x materialProperties block.
        let slotNames = vrm0MaterialNames(document)
        let materials = document.materials ?? []
        let slotOfMaterial: [Int: VRoidMaterialSlot] = Dictionary(uniqueKeysWithValues: materials.indices.map {
            ($0, VRoidMaterialSlot.classify(materialName: slotNames[$0] ?? materials[$0].name))
        })

        // UV footprint + index count per slot from the donor's own
        // primitives (CPU read of TEXCOORD_0 + indices; no GPU).
        var uvBySlot: [VRoidMaterialSlot: UVCoverageMask] = [:]
        var indexCountBySlot: [VRoidMaterialSlot: Int] = [:]
        for mesh in document.meshes ?? [] {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.material, let slot = slotOfMaterial[materialIndex], slot != .other,
                    let uvAccessor = primitive.attributes["TEXCOORD_0"],
                    let indexAccessor = primitive.indices,
                    let uvFlat = try? bufferLoader.loadAccessorAsFloat(uvAccessor),
                    let indices = try? bufferLoader.loadAccessorAsUInt32(indexAccessor)
                else { continue }
                let uvs = stride(from: 0, to: (uvFlat.count / 2) * 2, by: 2).map { SIMD2<Float>(uvFlat[$0], uvFlat[$0 + 1]) }
                var mask = uvBySlot[slot] ?? UVCoverageMask()
                mask.formUnion(UVCoverageMask.rasterize(uvs: uvs, indices: indices))
                uvBySlot[slot] = mask
                indexCountBySlot[slot, default: 0] += indices.count
            }
        }

        var slots: [VRoidMaterialSlot: DonorSlotTexture] = [:]
        var partTextures: [AppearancePartKind: Set<Int>] = [:]
        let vrm0TextureIndices = vrm0TextureIndicesByMaterial(document)
        for (materialIndex, material) in materials.enumerated() {
            guard let slot = slotOfMaterial[materialIndex], slot != .other else { continue }
            let referenced = textureIndices(of: material).union(vrm0TextureIndices[materialIndex] ?? [])
            for kind in AppearancePartKind.allCases where kind.slots.contains(slot) {
                partTextures[kind, default: []].formUnion(referenced)
            }
            guard slots[slot] == nil,
                let textureIndex = material.pbrMetallicRoughness?.baseColorTexture?.index,
                let source = document.textures?[safe: textureIndex]?.source,
                let image = document.images?[safe: source],
                let bufferViewIndex = image.bufferView,
                let bufferView = document.bufferViews?[safe: bufferViewIndex],
                bufferView.buffer == 0, let binaryChunkStart
            else { continue }
            let start = binaryChunkStart + (bufferView.byteOffset ?? 0)
            let range = start..<(start + bufferView.byteLength)
            guard range.upperBound <= data.count else { continue }
            let imageData = data.subdata(in: range)
            guard let size = imageSize(imageData) else { continue }
            slots[slot] = DonorSlotTexture(
                slot: slot,
                textureIndex: textureIndex,
                mimeType: image.mimeType,
                fileURL: url,
                imageByteRange: range,
                imageHash: SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined(),
                indexCount: indexCountBySlot[slot] ?? 0,
                uvCoverage: uvBySlot[slot] ?? UVCoverageMask(),
                width: size.width,
                height: size.height)
        }
        nlLog("[DonorScan] \(slug): \(slots.count) slots from \(url.lastPathComponent)")
        return DonorScan(slug: slug.lowercased(), url: url, slots: slots, partTextureIndices: partTextures)
    }

    // MARK: - Helpers

    /// Offset of the GLB BIN chunk payload (header 12 + JSON chunk header 8
    /// + JSON length + BIN chunk header 8), or nil for a non-GLB file.
    nonisolated private static func glbBinaryChunkStart(_ data: Data) -> Int? {
        guard data.count >= 28 else { return nil }
        let magic = data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x4654_6C67 else { return nil }
        let jsonLength = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) })
        let binStart = 20 + jsonLength + 8
        return binStart <= data.count ? binStart : nil
    }

    /// Every texture index a glTF material references (PBR slots + any
    /// `…Texture: {index}` inside its extensions, which covers MToon 1.0).
    nonisolated private static func textureIndices(of material: GLTFMaterial) -> Set<Int> {
        var indices = Set<Int>()
        if let i = material.pbrMetallicRoughness?.baseColorTexture?.index { indices.insert(i) }
        if let i = material.normalTexture?.index { indices.insert(i) }
        if let i = material.emissiveTexture?.index { indices.insert(i) }
        if let extensions = material.extensions {
            for (_, value) in extensions {
                guard let dict = value as? [String: Any] else { continue }
                for (key, entry) in dict where key.hasSuffix("Texture") {
                    if let info = entry as? [String: Any], let i = info["index"] as? Int { indices.insert(i) }
                }
            }
        }
        return indices
    }

    /// VRM 0.x `materialProperties[i].textureProperties` values, positionally.
    nonisolated private static func vrm0TextureIndicesByMaterial(_ document: GLTFDocument) -> [Int: Set<Int>] {
        guard let vrm = document.extensions?["VRM"] as? [String: Any],
            let properties = vrm["materialProperties"] as? [[String: Any]]
        else { return [:] }
        var result: [Int: Set<Int>] = [:]
        for (index, property) in properties.enumerated() {
            if let textures = property["textureProperties"] as? [String: Int] {
                result[index] = Set(textures.values)
            }
        }
        return result
    }

    /// VRM 0.x `materialProperties[i].name`, positionally, when present and
    /// non-generic; else an exclusive "Hair…" mesh name. Nil entries fall
    /// back to the glTF material name.
    nonisolated private static func vrm0MaterialNames(_ document: GLTFDocument) -> [Int: String] {
        var names: [Int: String] = [:]
        if let vrm = document.extensions?["VRM"] as? [String: Any],
            let properties = vrm["materialProperties"] as? [[String: Any]] {
            for (index, property) in properties.enumerated() {
                if let name = property["name"] as? String, !VRMModel.isGenericMaterialName(name) {
                    names[index] = name
                }
            }
        }
        let meshes = (document.meshes ?? []).map { ($0.name, $0.primitives.compactMap(\.material)) }
        for index in (document.materials ?? []).indices where names[index] == nil {
            let gltfName = document.materials?[index].name
            guard gltfName == nil || VRMModel.isGenericMaterialName(gltfName ?? "") else { continue }
            if let meshName = VRMModel.exclusiveMeshName(forMaterial: index, meshes: meshes) { names[index] = meshName }
        }
        return names
    }

    /// Pixel size without a full decode (ImageIO reads the header only).
    nonisolated private static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
