//
//  UVCoverageMask.swift
//  NeuraLink
//
//  A 64×64 occupancy grid over UV space. Two uses:
//    • target side — which atlas cells a primitive's triangles sample;
//    • donor side  — which cells of a texture are painted (alpha > 0.5).
//  A donor texture is compatible with a target slot when the target's cells
//  are (almost) all painted in the donor. VRoid shares the face/body atlas
//  between models, but the small eye-detail sub-meshes (iris, highlight,
//  eyeline, brows) sit in different places per model, so this check is what
//  keeps "borrow Sonya's brows" from painting garbage on Ekaterina.
//

import Foundation
import Metal

nonisolated public struct UVCoverageMask: Sendable, Equatable {
    public static let resolution = 64

    /// One UInt64 per row; bit x set = cell (x, row) covered.
    public private(set) var rows: [UInt64]

    public init() {
        rows = Array(repeating: 0, count: Self.resolution)
    }

    public mutating func mark(x: Int, y: Int) {
        guard x >= 0, y >= 0, x < Self.resolution, y < Self.resolution else { return }
        rows[y] |= (1 << UInt64(x))
    }

    public func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < Self.resolution, y < Self.resolution else { return false }
        return rows[y] & (1 << UInt64(x)) != 0
    }

    public var count: Int {
        rows.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    public var isEmpty: Bool { rows.allSatisfy { $0 == 0 } }

    public mutating func formUnion(_ other: UVCoverageMask) {
        for i in 0..<Self.resolution { rows[i] |= other.rows[i] }
    }

    /// |self ∩ other| / |self|. 1.0 when every cell this mask uses is also
    /// present in `other`; 0 when this mask is empty.
    public func fraction(coveredBy other: UVCoverageMask) -> Float {
        let total = count
        guard total > 0 else { return 0 }
        var hit = 0
        for i in 0..<Self.resolution { hit += (rows[i] & other.rows[i]).nonzeroBitCount }
        return Float(hit) / Float(total)
    }

    // MARK: - Builders

    /// Conservative triangle rasterization: every cell touched by a
    /// triangle's UV bounding box is marked. UVs outside [0,1) wrap (glTF
    /// REPEAT), which is what VRoid atlases assume.
    public static func rasterize(uvs: [SIMD2<Float>], indices: [UInt32]) -> UVCoverageMask {
        var mask = UVCoverageMask()
        let res = Float(resolution)
        let triCount = indices.count / 3
        for t in 0..<triCount {
            let i0 = Int(indices[t * 3]), i1 = Int(indices[t * 3 + 1]), i2 = Int(indices[t * 3 + 2])
            guard i0 < uvs.count, i1 < uvs.count, i2 < uvs.count else { continue }
            let a = wrap(uvs[i0]), b = wrap(uvs[i1]), c = wrap(uvs[i2])
            let minX = Int((min(a.x, b.x, c.x) * res).rounded(.down))
            let maxX = Int((max(a.x, b.x, c.x) * res).rounded(.down))
            let minY = Int((min(a.y, b.y, c.y) * res).rounded(.down))
            let maxY = Int((max(a.y, b.y, c.y) * res).rounded(.down))
            // A triangle that wraps across the atlas edge would fill a huge
            // box; treat it as covering nothing rather than everything.
            guard maxX - minX < resolution / 2, maxY - minY < resolution / 2 else { continue }
            for y in minY...maxY {
                for x in minX...maxX { mask.mark(x: x, y: y) }
            }
        }
        return mask
    }

    private static func wrap(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        var u = uv.x - uv.x.rounded(.down)
        var v = uv.y - uv.y.rounded(.down)
        if u >= 1 { u = 0.99999 }
        if v >= 1 { v = 0.99999 }
        return SIMD2<Float>(u, v)
    }

    /// Marks cells whose down-sampled alpha exceeds `threshold`. `alpha` is
    /// a `resolution × resolution` row-major byte grid (row 0 = image top,
    /// matching glTF's v = 0 at the top).
    public static func fromAlphaGrid(_ alpha: [UInt8], threshold: UInt8 = 128) -> UVCoverageMask {
        var mask = UVCoverageMask()
        guard alpha.count >= resolution * resolution else { return mask }
        for y in 0..<resolution {
            for x in 0..<resolution where alpha[y * resolution + x] >= threshold {
                mask.mark(x: x, y: y)
            }
        }
        return mask
    }
}

// MARK: - Primitive coverage

extension VRMPrimitive {
    /// Rasterizes this primitive's UV footprint from its shared-storage GPU
    /// buffers. Nil when the primitive has no UVs, no indices, or was loaded
    /// without a Metal device.
    public func computeUVCoverage() -> UVCoverageMask? {
        guard hasTexCoords, vertexCount > 0, indexCount > 0,
            let vertexBuffer, let indexBuffer,
            vertexBuffer.storageMode == .shared, indexBuffer.storageMode == .shared
        else { return nil }

        let stride = MemoryLayout<VRMVertex>.stride
        guard let uvOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.texCoord),
            vertexBuffer.length >= vertexCount * stride
        else { return nil }

        let base = vertexBuffer.contents()
        var uvs = [SIMD2<Float>](repeating: .zero, count: vertexCount)
        for i in 0..<vertexCount {
            uvs[i] = base.load(fromByteOffset: i * stride + uvOffset, as: SIMD2<Float>.self)
        }

        var indices = [UInt32](repeating: 0, count: indexCount)
        let indexBase = indexBuffer.contents().advanced(by: indexBufferOffset)
        switch indexType {
        case .uint16:
            guard indexBuffer.length >= indexBufferOffset + indexCount * 2 else { return nil }
            for i in 0..<indexCount {
                indices[i] = UInt32(indexBase.load(fromByteOffset: i * 2, as: UInt16.self))
            }
        case .uint32:
            guard indexBuffer.length >= indexBufferOffset + indexCount * 4 else { return nil }
            for i in 0..<indexCount {
                indices[i] = indexBase.load(fromByteOffset: i * 4, as: UInt32.self)
            }
        @unknown default:
            return nil
        }
        return UVCoverageMask.rasterize(uvs: uvs, indices: indices)
    }
}
