//
//  VRMModel+SlotBounds.swift
//  NeuraLink
//
//  Rest-pose bounding box of the primitives drawn with a given set of
//  customization slots. Used to frame a thumbnail on one garment while the
//  body is still drawn behind it — VRoid rigs bind at rest, so the stored
//  vertex positions are where the part sits before any animation.
//

import Foundation
import Metal
import simd

extension VRMPrimitive {

    /// Samples the rest positions this primitive actually draws.
    ///
    /// VRoid merges a whole body into ONE vertex array and slices it per
    /// primitive with indices, so reading that array directly reports the
    /// entire model for every garment sitting on it. Only the indexed
    /// vertices are this primitive's own.
    func forEachRestPosition(budget: Int, _ body: (SIMD3<Float>) -> Void) {
        guard let positionOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.position),
            let vertexBuffer, vertexBuffer.storageMode == .shared,
            vertexCount > 0,
            vertexBuffer.length >= vertexCount * MemoryLayout<VRMVertex>.stride
        else { return }
        let stride = MemoryLayout<VRMVertex>.stride
        let base = vertexBuffer.contents()
        func emit(_ vertex: Int) {
            guard vertex < vertexCount else { return }
            let position = base.load(
                fromByteOffset: vertex * stride + positionOffset, as: SIMD3<Float>.self)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
            body(position)
        }
        guard let indexBuffer, indexBuffer.storageMode == .shared, indexCount > 0 else {
            // Unindexed: the array belongs to this primitive alone.
            let step = max(1, vertexCount / budget)
            for i in Swift.stride(from: 0, to: vertexCount, by: step) { emit(i) }
            return
        }
        let indexBase = indexBuffer.contents().advanced(by: indexBufferOffset)
        var step = max(1, indexCount / budget)
        if step % 3 != 0 { step += 3 - (step % 3) }
        for n in Swift.stride(from: 0, to: indexCount, by: step) {
            switch indexType {
            case .uint16: emit(Int(indexBase.load(fromByteOffset: n * 2, as: UInt16.self)))
            case .uint32: emit(Int(indexBase.load(fromByteOffset: n * 4, as: UInt32.self)))
            @unknown default: return
            }
        }
    }

    /// Vertical extent of this primitive's own vertices at rest.
    public func restHeightRange() -> (min: Float, max: Float)? {
        var lo = Float.infinity, hi = -Float.infinity
        forEachRestPosition(budget: 1_200) { position in
            lo = min(lo, position.y)
            hi = max(hi, position.y)
        }
        return lo <= hi ? (lo, hi) : nil
    }
}

extension VRMModel {

    /// Size of the head this model's parts were built around. Measured from
    /// its own face geometry, or read from the value the part extractor
    /// recorded — a hair part keeps no face to measure.
    public var referenceHeadSize: SIMD3<Float>? {
        if let recorded = gltf.extras?["NL_headSize"]?.value as? [Any] {
            let numbers = recorded.compactMap { ($0 as? NSNumber)?.floatValue }
            if numbers.count == 3, numbers.allSatisfy({ $0 > 0 }) {
                return SIMD3<Float>(numbers[0], numbers[1], numbers[2])
            }
        }
        guard let bounds = restBounds(ofSlots: [.faceSkin]) else { return nil }
        let size = bounds.max - bounds.min
        return size.x > 0 && size.y > 0 ? size : nil
    }

    /// Foot length from the humanoid rig. Shoes are rigid on the foot the
    /// same way hair is rigid on the head, so a shoe cut for a small foot
    /// has to be resized for a bigger one. The rig is measured rather than
    /// the geometry because a shoes part file contains only the shoe.
    public var referenceFootLength: Float? {
        for pair in [(VRMHumanoidBone.leftFoot, VRMHumanoidBone.leftToes),
                     (VRMHumanoidBone.rightFoot, VRMHumanoidBone.rightToes)] {
            guard let foot = bindPosition(of: pair.0), let toes = bindPosition(of: pair.1)
            else { continue }
            let length = simd_distance(foot, toes)
            if length > 0.001 { return length }
        }
        return nil
    }

    /// Bind-pose position of a humanoid bone, recovered from the inverse
    /// bind matrix a skin holds for it.
    ///
    /// `node.worldPosition` is the CURRENT pose. By the time a graft runs,
    /// `VRMMetalState.display` has already started the idle animation, so
    /// the skeleton has moved — and measuring a moved ankle against
    /// rest-space geometry (`restBounds`) put grafted shoes through the
    /// floor. Everything a graft measures has to be in one space, and the
    /// bind pose is the one the geometry is stored in.
    public func bindPosition(of bone: VRMHumanoidBone) -> SIMD3<Float>? {
        guard let index = humanoid?.getBoneNode(bone), index < nodes.count else { return nil }
        let node = nodes[index]
        for skin in skins {
            guard let joint = skin.joints.firstIndex(where: { $0 === node }),
                joint < skin.inverseBindMatrices.count
            else { continue }
            let bind = skin.inverseBindMatrices[joint].inverse.columns.3
            guard bind.y.isFinite else { continue }
            return SIMD3<Float>(bind.x, bind.y, bind.z)
        }
        // Unskinned rigs never animate away from their rest pose.
        return node.worldPosition
    }

    /// Nil when nothing is drawn with those slots, or the geometry is not
    /// readable (no Metal device, private storage).
    public func restBounds(ofSlots slots: Set<VRoidMaterialSlot>) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        var found = false
        for mesh in meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex,
                    slots.contains(slot(ofMaterial: materialIndex))
                else { continue }
                // Sampling is plenty for a camera frame and keeps this cheap
                // on the 10k-vertex meshes VRoid produces.
                primitive.forEachRestPosition(budget: 2_000) { position in
                    lo = simd_min(lo, position)
                    hi = simd_max(hi, position)
                    found = true
                }
            }
        }
        return found ? (lo, hi) : nil
    }
}
