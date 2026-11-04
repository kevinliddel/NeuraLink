//
//  VRMPartGrafter+BareFoot.swift
//  NeuraLink
//
//  The foot a shoe was modelled around comes with the shoe.
//
//  The host's own foot is trimmed out from under a borrowed shoe
//  (VRMPartGrafter+SkinTrim): a flat foot cannot sit inside a heel, so it
//  pushes through the shell. A closed shoe hides the hole that leaves; an
//  open one — a sandal, a strappy heel — shows a leg ending in a sole with
//  no toes. The donor's body skin under the same line IS the foot that shoe
//  was shaped around, arched and toed to match, so it is grafted with the
//  shoe, bound the same way, and drawn in the HOST's skin: its material,
//  and its own texture coordinates (`wearHostSkin`).
//
//  Created by Dedicatus on 26/10/2026.
//

import Foundation
import Metal
import simd

extension VRMPartGrafter {

    /// The borrowed foot of a shoe graft: clipped copies of the donor's body
    /// skin, keyed by the donor primitive each came from, and the host body
    /// whose material and UV layout they take on.
    struct BareFoot {
        var clones: [ObjectIdentifier: VRMPrimitive] = [:]
        var hostSkin: VRMPrimitive?
    }

    /// The donor's body skin cut down to the triangles under the host's skin
    /// line, drawn with a copy of the host's skin material (appended to the
    /// host's materials; the composition's restore drops it with the rest
    /// of the graft). Empty when the part does not replace host skin, the
    /// donor carries no body skin (a shoe part extracted before feet were),
    /// or the host has no body of its own showing to lend its skin.
    static func bareFoot(
        _ kind: AppearancePartKind, donor: VRMModel, host: VRMModel, fit: Float, cut: Float?
    ) -> BareFoot {
        guard kind.trimsHostSkinUnderneath, let cut, fit > 0.0001,
            let device = host.device,
            let hostSkin = visibleOwnSkin(of: host), let material = hostSkin.materialIndex,
            let donorAnkle = donor.bindPosition(of: .leftFoot) ?? donor.bindPosition(of: .rightFoot),
            let hostAnkle = host.bindPosition(of: .leftFoot) ?? host.bindPosition(of: .rightFoot)
        else { return BareFoot() }
        // The foot bone places the shoe: donor height h lands at
        // hostAnkle + fit·(h − donorAnkle) in the host's bind pose. Inverted,
        // that is the donor height where the host's skin now stops, so the
        // two skins meet instead of overlapping or leaving a gap.
        let line = donorAnkle.y + (cut - hostAnkle.y) / fit
        var foot = BareFoot(hostSkin: hostSkin)
        for mesh in donor.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                    donor.slot(ofMaterial: materialIndex) == .bodySkin,
                    let clone = primitive.clippedClone(device: device, keeping: { $0.y < line })
                else { continue }
                foot.clones[ObjectIdentifier(primitive)] = clone
            }
        }
        guard !foot.clones.isEmpty, material < host.materials.count else { return BareFoot() }
        // The host's skin, drawn from both sides. Where the borrowed foot is
        // wider than the shin it meets, its rim is open, and looking into it
        // with back faces culled showed the inside of its outline hull: dark
        // spikes above the vamp. From both sides the inside reads as skin.
        // The outline stays — it is what draws the toes apart.
        let skin = VRMMaterial(copying: host.materials[material])
        skin.slotHint = .bodySkin
        skin.doubleSided = true
        host.materials.append(skin)
        for clone in foot.clones.values { clone.materialIndex = host.materials.count - 1 }
        return foot
    }

    /// The host's own body as drawn now. Only its OWN: its rest positions
    /// are then its bind pose, which `wearHostSkin` relies on. (A grafted
    /// outfit's body never shares the stage with shoes — each clears the
    /// other.)
    private static func visibleOwnSkin(of host: VRMModel) -> VRMPrimitive? {
        var best: VRMPrimitive?
        for mesh in host.composition?.snapshot.meshes ?? host.meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                    host.slot(ofMaterial: materialIndex) == .bodySkin,
                    !host.hiddenPrimitives.contains(ObjectIdentifier(primitive)),
                    primitive.indexCount > (best?.indexCount ?? 0)
                else { continue }
                best = primitive
            }
        }
        return best
    }

    /// Re-maps a borrowed foot onto the host's UV layout. False when it
    /// could not be, and the foot should not be drawn.
    ///
    /// VRoid has shipped more than one body unwrap. The toes sit at the same
    /// UVs in all of them, but the heel and instep moved (≈(0.53, 0.74) in
    /// one, (0.62, 0.67) in the other), so the donor's own coordinates read
    /// the host's texture off the edge of its foot — dark patches across
    /// the instep. Instead every corner takes the UV of the nearest host
    /// foot vertex, both feet placed in the host's bind pose (the borrowed
    /// one through the skin it has just been given). Triangles get corners
    /// of their own, and one whose corners land on different UV islands
    /// takes a single UV, so none stretches across the texture between them.
    static func wearHostSkin(
        _ foot: VRMPrimitive, skin: VRMSkin, host: VRMModel, hostSkin: VRMPrimitive
    ) -> Bool {
        guard let device = host.device,
            let ankle = host.bindPosition(of: .leftFoot) ?? host.bindPosition(of: .rightFoot),
            let hostFoot = hostSkin.indexedVertices(where: { $0.y < ankle.y + 0.04 }),
            hostFoot.count > 30,
            let corners = foot.indexedTriangleCorners()
        else { return false }
        let palette: [simd_float4x4?] = skin.joints.enumerated().map { slot, node in
            guard slot < skin.inverseBindMatrices.count,
                let bind = host.bindMatrix(ofNode: node) else { return nil }
            return bind * skin.inverseBindMatrices[slot]
        }
        func placed(_ vertex: VRMVertex) -> SIMD3<Float>? {
            var sum = SIMD4<Float>(repeating: 0)
            var total: Float = 0
            for k in 0..<4 where vertex.weights[k] > 0 {
                let slot = Int(vertex.joints[k])
                guard slot < palette.count, let matrix = palette[slot] else { continue }
                sum += matrix * SIMD4<Float>(vertex.position, 1) * vertex.weights[k]
                total += vertex.weights[k]
            }
            return total > 0.001 ? SIMD3<Float>(sum.x, sum.y, sum.z) / total : nil
        }
        func nearestUV(to point: SIMD3<Float>) -> SIMD2<Float> {
            var best = hostFoot[0]
            var bestDistance = Float.greatestFiniteMagnitude
            for sample in hostFoot {
                let distance = simd_distance_squared(sample.position, point)
                if distance < bestDistance { best = sample; bestDistance = distance }
            }
            return best.texCoord
        }

        var vertices: [VRMVertex] = []
        vertices.reserveCapacity(corners.count)
        for first in stride(from: 0, to: corners.count - 2, by: 3) {
            var triangle = [corners[first], corners[first + 1], corners[first + 2]]
            let points = triangle.map(placed)
            guard let a = points[0], let b = points[1], let c = points[2] else { continue }
            var uvs = [nearestUV(to: a), nearestUV(to: b), nearestUV(to: c)]
            let spread = max(simd_distance(uvs[0], uvs[1]), simd_distance(uvs[1], uvs[2]),
                             simd_distance(uvs[0], uvs[2]))
            if spread > 0.03 {
                let centre = nearestUV(to: (a + b + c) / 3)
                uvs = [centre, centre, centre]
            }
            for k in 0..<3 { triangle[k].texCoord = uvs[k] }
            vertices.append(contentsOf: triangle)
        }
        guard vertices.count >= 3,
            let vertexBuffer = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        else { return false }
        let indices = (0..<UInt32(vertices.count)).map { $0 }
        guard let indexBuffer = indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
        else { return false }
        foot.vertexBuffer = vertexBuffer
        foot.vertexCount = vertices.count
        foot.indexBuffer = indexBuffer
        foot.indexCount = indices.count
        foot.indexType = .uint32
        foot.indexBufferOffset = 0
        // Morphs were indexed by the donor's vertices, which are gone; a
        // foot has none worth keeping.
        foot.morphTargets = []
        foot.morphPositionBuffers = []
        foot.morphNormalBuffers = []
        foot.morphTangentBuffers = []
        foot.morphPositionsSoA = nil
        foot.morphNormalsSoA = nil
        foot.basePositionsBuffer = nil
        foot.baseNormalsBuffer = nil
        return true
    }
}

extension VRMPrimitive {

    /// Each vertex the index buffer references whose position passes
    /// `include`, once.
    fileprivate func indexedVertices(where include: (SIMD3<Float>) -> Bool) -> [VRMVertex]? {
        var seen = Set<Int>()
        var vertices: [VRMVertex] = []
        let readable = forEachIndexedVertex { index, vertex in
            if include(vertex.position), seen.insert(index).inserted { vertices.append(vertex) }
        }
        return readable ? vertices : nil
    }

    /// The vertex at every index, in draw order (three per triangle).
    fileprivate func indexedTriangleCorners() -> [VRMVertex]? {
        var corners: [VRMVertex] = []
        corners.reserveCapacity(indexCount)
        return forEachIndexedVertex { _, vertex in corners.append(vertex) } ? corners : nil
    }

    /// Visits the vertex at every index. False when the buffers are not
    /// CPU-readable or an index is out of range.
    private func forEachIndexedVertex(_ body: (Int, VRMVertex) -> Void) -> Bool {
        guard let vertexBuffer, vertexBuffer.storageMode == .shared,
            let indexBuffer, indexBuffer.storageMode == .shared, indexCount >= 3,
            vertexBuffer.length >= vertexCount * MemoryLayout<VRMVertex>.stride
        else { return false }
        let vertexBase = vertexBuffer.contents()
        let indexBase = indexBuffer.contents().advanced(by: indexBufferOffset)
        for n in 0..<indexCount {
            let index = indexType == .uint32
                ? Int(indexBase.load(fromByteOffset: n * 4, as: UInt32.self))
                : Int(indexBase.load(fromByteOffset: n * 2, as: UInt16.self))
            guard index < vertexCount else { return false }
            body(index, vertexBase.load(
                fromByteOffset: index * MemoryLayout<VRMVertex>.stride, as: VRMVertex.self))
        }
        return true
    }
}
