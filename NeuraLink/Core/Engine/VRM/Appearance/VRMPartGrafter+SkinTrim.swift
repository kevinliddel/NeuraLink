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
    static func trimHostSkin(
        under kind: AppearancePartKind, in host: VRMModel, donor: VRMModel, fit: Float,
        below cut: Float
    ) -> Int {
        guard kind.trimsHostSkinUnderneath, let device = host.device else { return 0 }
        // Restricting this to the shoe's ground plan was tried and is far
        // worse: it spares the toes but leaves every bit of foot the shoe
        // fails to cover, and measured exposure went from 2 pairs at 1.7% to
        // 9 pairs at 58%. The skin outside the shell is exactly what has to
        // go — which is why a heel the foot cannot fit into reads as missing
        // toes whichever way this is set.
        var trimmed = 0
        for mesh in host.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                    host.slot(ofMaterial: materialIndex) == .bodySkin,
                    !host.hiddenPrimitives.contains(ObjectIdentifier(primitive)),
                    primitive.untrimmedIndices == nil
                else { continue }
                let dropped = primitive.dropTriangles(device: device) { $0.y < cut }
                if dropped { trimmed += 1 }
            }
        }
        if trimmed > 0 {
            nlLog(
                "[Graft] trimmed host skin below \(String(format: "%.3f", cut)) under \(kind.rawValue)",
                level: .debug)
        }
        return trimmed
    }

    /// How far a shoe's sole hangs below the ankle it is bound to — the
    /// depth of the cavity the foot has to fit into.
    static func ankleAboveSole(of model: VRMModel, slots: Set<VRoidMaterialSlot>) -> Float? {
        guard let ankle = model.bindPosition(of: .leftFoot) ?? model.bindPosition(of: .rightFoot),
            let sole = model.restBounds(ofSlots: slots)?.min.y
        else { return nil }
        let depth = ankle.y - sole
        return depth > 0.0001 ? depth : nil
    }

    /// How deep a shoe must be to hold this figure's foot.
    ///
    /// Taken from the shoe it already wears, which is by definition deep
    /// enough for it. Measuring the bare foot instead compares a different
    /// quantity — a shoe's depth includes its sole — and came out under 1
    /// every time, which the clamp then flattened to no change at all.
    static func footDepth(of model: VRMModel) -> Float? {
        if let own = ankleAboveSole(of: model, slots: AppearancePartKind.shoes.slots) {
            return own
        }
        guard let ankle = model.bindPosition(of: .leftFoot) ?? model.bindPosition(of: .rightFoot),
            let sole = model.restBounds(ofSlots: [.bodySkin])?.min.y
        else { return nil }
        let depth = ankle.y - sole
        return depth > 0.0001 ? depth : nil
    }

    /// Moves the whole figure up (or down) so a grafted shoe's sole reaches
    /// the ground it stands on.
    ///
    /// The alternative — sliding the shoe up to the floor — pulls its cavity
    /// off the foot it is meant to contain, and the foot ends up hanging
    /// outside. Across the library every shoe needing under ~23mm of slide
    /// looked right and every shoe needing more did not, which is what a
    /// heel is: a shoe whose ankle sits far above its sole.
    static func raiseFigure(by lift: Float, in host: VRMModel) {
        guard abs(lift) > 0.0005 else { return }
        for node in host.nodes where node.parent == nil {
            node.translation.y += lift
            node.updateLocalMatrix()
        }
        host.groundedShoeLift += lift
        host.updateNodeTransforms()
    }

    /// Puts the figure back down. Called by `restoreBaseComposition`, which
    /// restores the node ARRAY but not a translation changed in place.
    static func lowerFigure(in host: VRMModel) {
        let lift = host.groundedShoeLift
        guard lift != 0 else { return }
        for node in host.nodes where node.parent == nil {
            node.translation.y -= lift
            node.updateLocalMatrix()
        }
        host.groundedShoeLift = 0
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
            // DEPTH, not length. What puts a foot outside a shoe is the shoe
            // being too shallow to hold it: the sole hangs a fixed distance
            // below the ankle it is bound to, and anything the host's foot
            // reaches past that comes out the bottom. On Ekaterina the
            // exposed fraction tracked this exactly — 37% for the shallowest
            // donor, 4.7% and 1.1% for the next two, nothing for the rest.
            // A shoe has to be deep enough AND long enough. Depth decides
            // whether the foot drops out of the bottom, length whether the
            // toes and heel come out the ends, and a donor can satisfy one
            // while failing the other — a boot deeper than Sonya's own shoe
            // still left 13% of her longer foot outside it. Take whichever
            // demands more growth.
            var need: Float = 1
            if let donorDepth = ankleAboveSole(of: donor, slots: kind.slots),
                let hostDepth = footDepth(of: host), donorDepth > 0.0001 {
                need = max(need, hostDepth / donorDepth)
            }
            if let donorFoot = donor.referenceFootLength,
                let hostFoot = host.referenceFootLength, donorFoot > 0.0001 {
                need = max(need, hostFoot / donorFoot)
            }
            pair = need > 1 ? (1, need) : nil
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
    /// Ground plan of the grafted shoes in the host's bind space: one box
    /// per foot, from the donor's shoe scaled about its ankle and re-centred
    /// on the host's. Skin outside it is never touched.
    struct Footprint {
        var boxes: [(low: SIMD2<Float>, high: SIMD2<Float>)] = []
        /// Slack outward, so skin lying against the inside of the shell
        /// still counts as covered.
        static let slack: Float = 0.012

        func covers(_ point: SIMD3<Float>) -> Bool {
            guard !boxes.isEmpty else { return true }
            return boxes.contains { box in
                point.x > box.low.x - Self.slack && point.x < box.high.x + Self.slack
                    && point.z > box.low.y - Self.slack && point.z < box.high.y + Self.slack
            }
        }
    }

    static func shoeFootprint(
        donor: VRMModel, host: VRMModel, slots: Set<VRoidMaterialSlot>, fit: Float
    ) -> Footprint {
        var footprint = Footprint()
        for bone in [VRMHumanoidBone.leftFoot, .rightFoot] {
            guard let donorAnkle = donor.bindPosition(of: bone),
                let hostAnkle = host.bindPosition(of: bone)
            else { continue }
            var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            var found = false
            for mesh in donor.meshes {
                for primitive in mesh.primitives {
                    guard let materialIndex = primitive.materialIndex,
                        slots.contains(donor.slot(ofMaterial: materialIndex))
                    else { continue }
                    primitive.forEachRestPosition(budget: 20_000) { position in
                        guard abs(position.x - donorAnkle.x) < 0.12 else { return }
                        let mapped = SIMD2<Float>(
                            (position.x - donorAnkle.x) * fit + hostAnkle.x,
                            (position.z - donorAnkle.z) * fit + hostAnkle.z)
                        low = simd_min(low, mapped)
                        high = simd_max(high, mapped)
                        found = true
                    }
                }
            }
            if found { footprint.boxes.append((low, high)) }
        }
        return footprint
    }

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
        // Never take more of the HOST's foot than a shoe could plausibly
        // hide. The line above comes from the donor's collar, and on a rig
        // whose proportions differ from the donor's — an imported character,
        // say — that overshoots and removes the foot outright, leaving a gap
        // between leg and shoe. The host's own foot depth is the ceiling.
        var cut = floor + height * 0.9
        if let depth = footDepth(of: host) {
            cut = min(cut, floor + depth * 0.8)
        }
        return cut
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
    /// Depth of each band as a fraction of the deepest, from the last
    /// `collarHeight` call. Diagnostics only — this is how the rule's
    /// threshold gets chosen from measured shapes instead of guessed at.
    nonisolated(unsafe) static var lastProfile: [Float] = []

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
                // Dense: at 6k samples the per-band depths moved enough between
                // runs to shift the collar from 0.064 to 0.116 on the same shoe.
                primitive.forEachRestPosition(budget: 40_000) { position in
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
        // The HIGHEST band still at full depth, scanning the whole profile.
        // Stopping at the first break sounded principled and was wrong: a
        // shoe narrows just above its sole, and that one shallow band halted
        // the scan, leaving tall shoes cut at 0.012 with the shin showing
        // through the shaft. Across the whole profile a heel stops at its
        // vamp — its upper bands really are shallow — and a boot reaches its
        // collar, because its are not.
        lastProfile = depths.map { $0 / deepest }
        var top = 1
        for band in 0..<bands where depths[band] >= deepest * 0.6 { top = band + 1 }
        return lowest + Float(top) * bandHeight
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
    func dropTriangles(device: MTLDevice, where isHidden: (SIMD3<Float>) -> Bool) -> Bool {
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
            return isHidden(vertexBase.load(
                fromByteOffset: vertex * stride + positionOffset, as: SIMD3<Float>.self))
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
