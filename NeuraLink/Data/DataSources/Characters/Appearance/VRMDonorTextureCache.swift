//
//  VRMDonorTextureCache.swift
//  NeuraLink
//
//  Reads the base-colour textures of another character's VRM ("donor")
//  without loading it as a model: parse the GLB header, walk materials →
//  slots, and pull each slot's image bytes straight out of the binary chunk.
//  Cheap (no geometry, no GPU) and enough for the Unity reference's
//  "copy the materials from premade model N" — every character in the
//  registry, bundled or imported, becomes a texture donor.
//
//  Each slot also carries the texture's painted-area mask (alpha > 0.5) so
//  AppearanceApplier can reject donors whose atlas layout doesn't cover the
//  target's UVs (see UVCoverageMask).
//

import CoreGraphics
import Foundation
import ImageIO

/// One donor texture: encoded image bytes + its painted-area coverage.
nonisolated public struct DonorSlotTexture: Sendable {
    public let imageData: Data
    public let mimeType: String?
    /// Texels with alpha ≥ 0.5 — the criterion for MASK/BLEND slots.
    public let alphaCoverage: UVCoverageMask
    /// Texels carrying any colour — the criterion for slots the renderer
    /// draws opaque (body skin keeps skin colour under VRoid's alpha holes).
    public let colorCoverage: UVCoverageMask
    /// Atlas cells the donor's own geometry samples for this slot.
    public let uvCoverage: UVCoverageMask
    public let width: Int
    public let height: Int

    /// Cells a target may sample from this texture: everywhere the donor's
    /// own mesh samples (an iris texture is *meant* to be transparent
    /// outside the disc), plus painted texels — colour for body skin (drawn
    /// opaque), alpha for everything else.
    public func coverage(for slot: VRoidMaterialSlot) -> UVCoverageMask {
        var mask = uvCoverage
        mask.formUnion(slot == .bodySkin ? colorCoverage : alphaCoverage)
        return mask
    }
}

/// Everything usable from one donor file.
nonisolated public struct DonorScan: Sendable {
    public let slug: String
    public let url: URL
    public let slots: [VRoidMaterialSlot: DonorSlotTexture]

    /// Whether the donor has geometry for a graftable part.
    public func hasPart(_ kind: AppearancePartKind) -> Bool {
        switch kind {
        case .hair: return slots[.hair] != nil
        case .outfit: return slots[.tops] != nil || slots[.onepiece] != nil || slots[.bodySkin] != nil
        }
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

    /// Cap so a long session with many imports doesn't pin every donor's
    /// image bytes; scans are cheap to redo.
    private let maxEntries = 6

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

    public func invalidateAll() {
        cache.removeAll()
    }

    // MARK: - Scan

    nonisolated private static func performScan(url: URL, slug: String) throws -> DonorScan {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parser = GLTFParser()
        let (document, binaryData) = try parser.parse(data: data, filePath: url.path)
        let bufferLoader = BufferLoader(document: document, binaryData: binaryData, baseURL: url.deletingLastPathComponent())

        // UV footprint per slot from the donor's own primitives (CPU read of
        // TEXCOORD_0 + indices; no GPU).
        var uvBySlot: [VRoidMaterialSlot: UVCoverageMask] = [:]
        for mesh in document.meshes ?? [] {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.material,
                    let material = document.materials?[safe: materialIndex],
                    let uvAccessor = primitive.attributes["TEXCOORD_0"],
                    let indexAccessor = primitive.indices
                else { continue }
                let slot = VRoidMaterialSlot.classify(materialName: material.name)
                guard slot != .other,
                    let uvFlat = try? bufferLoader.loadAccessorAsFloat(uvAccessor),
                    let indices = try? bufferLoader.loadAccessorAsUInt32(indexAccessor)
                else { continue }
                let uvs = stride(from: 0, to: (uvFlat.count / 2) * 2, by: 2).map { SIMD2<Float>(uvFlat[$0], uvFlat[$0 + 1]) }
                var mask = uvBySlot[slot] ?? UVCoverageMask()
                mask.formUnion(UVCoverageMask.rasterize(uvs: uvs, indices: indices))
                uvBySlot[slot] = mask
            }
        }

        var slots: [VRoidMaterialSlot: DonorSlotTexture] = [:]
        for material in document.materials ?? [] {
            let slot = VRoidMaterialSlot.classify(materialName: material.name)
            guard slot != .other, slots[slot] == nil else { continue }
            guard let textureIndex = material.pbrMetallicRoughness?.baseColorTexture?.index,
                let source = document.textures?[safe: textureIndex]?.source,
                let image = document.images?[safe: source],
                let bufferViewIndex = image.bufferView,
                let bufferView = document.bufferViews?[safe: bufferViewIndex]
            else { continue }

            let bufferData = try bufferLoader.getBufferData(bufferIndex: bufferView.buffer)
            let offset = bufferView.byteOffset ?? 0
            let length = bufferView.byteLength
            guard offset + length <= bufferData.count else { continue }
            let imageData = bufferData.subdata(in: offset..<(offset + length))

            guard let masks = AppearanceTextureFactory.coverageMasks(imageData: imageData),
                let size = imageSize(imageData)
            else { continue }
            slots[slot] = DonorSlotTexture(
                imageData: imageData,
                mimeType: image.mimeType,
                alphaCoverage: masks.alpha,
                colorCoverage: masks.color,
                uvCoverage: uvBySlot[slot] ?? UVCoverageMask(),
                width: size.width,
                height: size.height)
        }
        nlLog("[DonorScan] \(slug): \(slots.count) slots from \(url.lastPathComponent)")
        return DonorScan(slug: slug.lowercased(), url: url, slots: slots)
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
