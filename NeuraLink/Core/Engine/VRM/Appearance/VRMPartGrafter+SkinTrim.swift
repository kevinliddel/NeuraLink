//
//  VRMPartGrafter+SkinTrim.swift
//  NeuraLink
//
//  How a rigid part is sized, grounded, and how the host's own skin is
//  taken out from under it.
//
//  VRoid leaves a whole foot in the body mesh. A character's own shoe is
//  modelled around that exact foot, but a shoe cut from a different body is
//  not, so the heel and the sides of the foot push through it. No uniform
//  scale fixes that: measured on Sonya, her foot skin reaches 0.048 further
//  back than a same-bone-length donor shoe and 0.022 wider on each side, so
//  the shell is a different SHAPE, not merely a different size — and
//  growing it enough to swallow the foot would leave a clown shoe.
//
//  The body is one merged primitive, so the foot cannot simply be hidden.
//  Instead the primitive keeps its vertices and gets a narrower index
//  buffer with the triangles under the shoe left out. The original buffer
//  is kept on the primitive so `restoreBaseComposition` puts it back.
//

import Foundation
import Metal
import simd

extension VRMPartGrafter {

    /// Drops host skin triangles below `cut`, in the host's own rest space.
    /// Returns how many primitives were trimmed.
    @discardableResult
    static func trimHostSkin(under kind: AppearancePartKind, in host: VRMModel, below cut: Float) -> Int {
        guard kind.trimsHostSkinUnderneath, let device = host.device else { return 0 }
        var trimmed = 0
        for mesh in host.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                    host.slot(ofMaterial: materialIndex) == .bodySkin,
                    !host.hiddenPrimitives.contains(ObjectIdentifier(primitive)),
                    primitive.untrimmedIndices == nil
                else { continue }
                if primitive.dropTriangles(below: cut, device: device) { trimmed += 1 }
            }
        }
        if trimmed > 0 {
            nlLog(
                "[Graft] trimmed host skin below \(String(format: "%.3f", cut)) under \(kind.rawValue)",
                level: .debug)
        }
        return trimmed
    }

    /// How much bigger the host's anchor is than the donor's, clamped so a
    /// bad or missing measurement can never wreck a part. Clothes return 1:
    /// they are skinned across the body and fit on their own.
    static func fitScale(_ kind: AppearancePartKind, donor: VRMModel, host: VRMModel) -> Float {
        let pair: (Float, Float)?
        switch kind {
        case .hair:
            if let a = donor.referenceHeadSize, let b = host.referenceHeadSize {
                pair = (simd_length(a), simd_length(b))
            } else {
                pair = nil
            }
        case .shoes:
            if let a = donor.referenceFootLength, let b = host.referenceFootLength {
                pair = (a, b)
            } else {
                pair = nil
            }
        case .outfit, .tops, .bottoms:
            pair = nil
        }
        guard let pair, pair.0 > 0.0001, pair.1 > 0.0001 else { return 1 }
        // A shoe is never shrunk. Hair can be: a smaller head wants smaller
        // hair, and hair sits ON the head. A shoe has to CONTAIN the foot,
        // and Ekaterina has the smallest feet in the set — shrinking a
        // borrowed shoe to her rig pushed her toes and instep straight
        // through the shell. Too big reads as a chunky shoe; too small
        // reads as broken.
        let smallest: Float = kind == .shoes ? 1 : 0.72
        return min(1.4, max(smallest, pair.1 / pair.0))
    }

    /// Where to cut the host's skin, in the HOST's rest space.
    ///
    /// Measuring the grafted shoe itself would be wrong: grafted geometry
    /// keeps the donor's vertices and is placed entirely by its inverse
    /// bind matrices, so its rest positions are still in the donor's frame.
    /// The shoe's sole is grounded to the host's floor, so its collar ends
    /// up one scaled shoe-height above that, and the cut sits just below.
    static func skinCutLine(
        _ kind: AppearancePartKind, donor: VRMModel, host: VRMModel, fit: Float
    ) -> Float? {
        guard kind.trimsHostSkinUnderneath,
            let shoe = donor.restBounds(ofSlots: kind.slots),
            let floor = floorHeight(of: host)
        else { return nil }
        // Where the shoe CLOSES around the leg, not the top of its box: a
        // heel's box is tall because of the heel, and a boot shaft reaches
        // far above the vamp the leg actually passes through. Trimming to
        // the box top cut the leg off above some shoes and left a gap.
        let opening = collarHeight(of: donor, slots: kind.slots) ?? shoe.max.y
        let height = (opening - shoe.min.y) * fit
        guard height > 0.0001 else { return nil }
        // Just under the opening. A triangle is only dropped when ALL THREE
        // of its corners are below the line, so the ones straddling it stay
        // and the leg still plugs it.
        return floor + height * 0.9
    }

    /// Height up to which the shoe is a SOLID shell around the foot, in the
    /// donor's rest space.
    ///
    /// Neither the box top nor the highest geometry near the ankle works: on
    /// a strap heel both of those are the strap, and the skin between the
    /// vamp and the strap is visible on the original character too, so
    /// trimming to it leaves a gap where the leg should be. What separates
    /// the two is depth — a vamp runs most of the foot's length, an ankle
    /// strap is a thin band. So this walks up in bands and returns the top
    /// of the highest one still as deep as the shoe's deepest.
    ///
    /// Under-shooting is safe: skin left inside a shoe that encloses it is
    /// hidden anyway. Over-shooting is what shows.
    static func collarHeight(of donor: VRMModel, slots: Set<VRoidMaterialSlot>) -> Float? {
        guard let ankle = donor.bindPosition(of: .leftFoot) ?? donor.bindPosition(of: .rightFoot)
        else { return nil }
        let reach = max((donor.referenceFootLength ?? 0.1) * 1.2, 0.06)
        let reachSquared = reach * reach
        var samples: [SIMD2<Float>] = []
        for mesh in donor.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                    slots.contains(donor.slot(ofMaterial: materialIndex))
                else { continue }
                primitive.forEachRestPosition(budget: 6_000) { position in
                    let dx = position.x - ankle.x, dz = position.z - ankle.z
                    guard dx * dx + dz * dz < reachSquared else { return }
                    samples.append(SIMD2<Float>(position.y, position.z))
                }
            }
        }
        guard samples.count > 24 else { return nil }
        let lowest = samples.lazy.map(\.x).min() ?? 0
        let highest = samples.lazy.map(\.x).max() ?? 0
        let span = highest - lowest
        guard span > 0.0001 else { return nil }

        let bands = 12
        let bandHeight = span / Float(bands)
        var low = [Float](repeating: .greatestFiniteMagnitude, count: bands)
        var high = [Float](repeating: -.greatestFiniteMagnitude, count: bands)
        for sample in samples {
            let band = min(bands - 1, max(0, Int((sample.x - lowest) / bandHeight)))
            low[band] = min(low[band], sample.y)
            high[band] = max(high[band], sample.y)
        }
        let depths = (0..<bands).map { high[$0] > low[$0] ? high[$0] - low[$0] : 0 }
        guard let deepest = depths.max(), deepest > 0.0001 else { return nil }
        var top = lowest + bandHeight
        for band in 0..<bands where depths[band] >= deepest * 0.6 {
            top = lowest + Float(band + 1) * bandHeight
        }
        return top
    }

    /// How far to lift or drop a part so it meets the floor the host stands
    /// on, in world units.
    ///
    /// A shoe is rigid on the foot bone, so it lands wherever the DONOR's
    /// ankle sat above its own sole. When the host's ankle sits at a
    /// different height, the shoe misses the ground: measured across the
    /// library, soles landed up to 63 mm under Sonya's floor and 37 mm above
    /// Ekaterina's. Zero when the part doesn't stand on the ground, or when
    /// anything needed could not be measured.
    static func groundOffset(
        _ kind: AppearancePartKind, donor: VRMModel, host: VRMModel, fit: Float
    ) -> Float {
        guard kind.standsOnTheFloor,
            let donorShoe = donor.restBounds(ofSlots: kind.slots),
            let donorAnkle = ankleHeight(of: donor),
            let hostAnkle = ankleHeight(of: host),
            let hostFloor = floorHeight(of: host)
        else { return 0 }
        // The sole lands this far under the host's ankle; we want it on the
        // host's floor instead.
        let drop = (donorAnkle - donorShoe.min.y) * fit
        let offset = hostFloor - (hostAnkle - drop)
        // A correction this large means something was mismeasured, not that
        // the shoe belongs underground.
        return abs(offset) < 0.12 ? offset : 0
    }

    /// Bind-pose ankle height. NOT `node.worldPosition`: the host is already
    /// animating by the time a graft runs, and measuring a moved ankle
    /// against a rest-space floor drove the shoes into the ground.
    private static func ankleHeight(of model: VRMModel) -> Float? {
        for bone in [VRMHumanoidBone.leftFoot, .rightFoot] {
            if let position = model.bindPosition(of: bone) { return position.y }
        }
        return nil
    }

    /// The ground this model stands on: the sole of its own shoes, or its
    /// bare feet when it has none.
    private static func floorHeight(of model: VRMModel) -> Float? {
        model.restBounds(ofSlots: AppearancePartKind.shoes.slots)?.min.y
            ?? model.restBounds(ofSlots: [.bodySkin])?.min.y
    }
}

extension VRMPrimitive {

    /// The index buffer this primitive had before a graft trimmed geometry
    /// out of it. Non-nil only while trimmed.
    public struct UntrimmedIndices {
        let buffer: MTLBuffer?
        let count: Int
        let offset: Int
    }

    /// Rebuilds the index buffer without the triangles whose three corners
    /// all sit below `y`. Vertices are untouched — they are shared with
    /// every other primitive on a VRoid body. Returns false when nothing
    /// qualified, so the caller can tell a no-op from a trim.
    func dropTriangles(below y: Float, device: MTLDevice) -> Bool {
        guard primitiveType == .triangle,
            let positionOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.position),
            let vertexBuffer, vertexBuffer.storageMode == .shared,
            let indexBuffer, indexBuffer.storageMode == .shared,
            indexCount >= 3, vertexCount > 0,
            vertexBuffer.length >= vertexCount * MemoryLayout<VRMVertex>.stride
        else { return false }

        let stride = MemoryLayout<VRMVertex>.stride
        let vertexBase = vertexBuffer.contents()
        let indexBase = indexBuffer.contents().advanced(by: indexBufferOffset)
        let wide = indexType == .uint32

        func index(_ n: Int) -> Int {
            wide
                ? Int(indexBase.load(fromByteOffset: n * 4, as: UInt32.self))
                : Int(indexBase.load(fromByteOffset: n * 2, as: UInt16.self))
        }
        func isUnder(_ vertex: Int) -> Bool {
            guard vertex < vertexCount else { return false }
            return vertexBase.load(
                fromByteOffset: vertex * stride + positionOffset, as: SIMD3<Float>.self).y < y
        }

        var kept32: [UInt32] = []
        var kept16: [UInt16] = []
        kept32.reserveCapacity(wide ? indexCount : 0)
        kept16.reserveCapacity(wide ? 0 : indexCount)
        var dropped = 0
        for triangle in stride2(indexCount) {
            let a = index(triangle), b = index(triangle + 1), c = index(triangle + 2)
            if isUnder(a), isUnder(b), isUnder(c) {
                dropped += 1
                continue
            }
            if wide {
                kept32.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
            } else {
                kept16.append(contentsOf: [UInt16(a), UInt16(b), UInt16(c)])
            }
        }
        guard dropped > 0 else { return false }

        let keptCount = wide ? kept32.count : kept16.count
        // Everything gone would mean the measurement was wrong, not that the
        // body should vanish. Leave it alone.
        guard keptCount >= 3 else { return false }
        let newBuffer: MTLBuffer? = wide
            ? kept32.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            : kept16.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        guard let newBuffer else { return false }

        untrimmedIndices = UntrimmedIndices(
            buffer: indexBuffer, count: indexCount, offset: indexBufferOffset)
        self.indexBuffer = newBuffer
        indexCount = keptCount
        indexBufferOffset = 0
        return true
    }

    /// Puts the full index buffer back. No-op when never trimmed.
    func restoreUntrimmedIndices() {
        guard let original = untrimmedIndices else { return }
        indexBuffer = original.buffer
        indexCount = original.count
        indexBufferOffset = original.offset
        untrimmedIndices = nil
    }

    private func stride2(_ count: Int) -> StrideTo<Int> {
        Swift.stride(from: 0, to: count - 2, by: 3)
    }
}
