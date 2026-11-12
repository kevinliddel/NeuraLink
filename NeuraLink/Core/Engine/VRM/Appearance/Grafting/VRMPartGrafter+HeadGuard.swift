//
//  VRMPartGrafter+HeadGuard.swift
//  NeuraLink
//
//  A whole outfit stops at the neck. VRoid's body mesh reaches into the
//  head (the scalp cap that hides under the hair, the top of the neck) and
//  an outfit's accessories often sit on it (glasses, hairpins, ears), all
//  shaped for the DONOR's head. Grafted onto a host with a smaller head
//  they came through the host's hair as patches of skin. So an outfit
//  graft leaves the head to the host: the donor's triangles that ride the
//  head bone are not brought over, and the host's own are kept instead of
//  being hidden with the rest of its body.
//
//  "Rides the head" is read from the skin weights, never from a height:
//  a triangle belongs to the head when the strongest joint of each of its
//  three corners is the head bone or a bone under it. Triangles that
//  straddle the neck stay with the outfit, so the neck it brings is whole.
//
//  Created by Dedicatus on 10/11/2026.
//

import Foundation
import Metal
import simd

extension VRMPartGrafter {

    /// Whether a primitive in `slot` leaves the head to the host when
    /// `kind` is grafted: the skin and the accessories of a whole outfit.
    /// Garments are skinned across the body and are brought whole.
    static func guardsHead(_ kind: AppearancePartKind, slot: VRoidMaterialSlot?) -> Bool {
        kind == .outfit && (slot == .bodySkin || slot == .accessory)
    }

    /// A donor primitive as drawn by one donor node. One mesh can hang
    /// from two nodes (one on the head, one not), and what the graft
    /// brings of it depends on the node.
    struct GraftKey: Hashable {
        let node: ObjectIdentifier
        let primitive: ObjectIdentifier

        init(_ node: VRMNode, _ primitive: VRMPrimitive) {
            self.node = ObjectIdentifier(node)
            self.primitive = ObjectIdentifier(primitive)
        }
    }

    /// What the graft brings for every selected donor primitive (the ones
    /// in `skipping` are handled elsewhere), keyed by node and primitive.
    /// Empty when the head guard leaves nothing of the part.
    static func graftSources(
        _ selection: [(node: VRMNode, mesh: VRMMesh, primitives: [VRMPrimitive])], kind: AppearancePartKind,
        donor: VRMModel, device: MTLDevice?, skipping: [ObjectIdentifier: VRMPrimitive]
    ) -> [GraftKey: VRMPrimitive] {
        var sources: [GraftKey: VRMPrimitive] = [:]
        for entry in selection {
            for primitive in entry.primitives where skipping[ObjectIdentifier(primitive)] == nil {
                sources[GraftKey(entry.node, primitive)] = graftSource(
                    primitive, kind: kind, node: entry.node, donor: donor, device: device)
            }
        }
        return sources
    }

    /// What a graft of `kind` brings of a donor primitive: all of it,
    /// except for an outfit's skin and accessories, which stop at the neck.
    static func graftSource(
        _ primitive: VRMPrimitive, kind: AppearancePartKind, node: VRMNode, donor: VRMModel, device: MTLDevice?
    ) -> VRMPrimitive? {
        let slot = primitive.materialIndex.flatMap { $0 < donor.materials.count ? donor.slot(ofMaterial: $0) : nil }
        guard guardsHead(kind, slot: slot) else { return primitive }
        return belowTheHead(primitive, node: node, donor: donor, device: device)
    }

    /// Hides whatever already occupied the part's slots — the host's own
    /// geometry and anything an earlier graft put there, so choosing a
    /// single garment overrides a whole-outfit pick — except the host's
    /// own head under a borrowed outfit: the scalp cap that fits its hair,
    /// its glasses. Returns how many primitives were hidden.
    static func hideOccupants(of kind: AppearancePartKind, in host: VRMModel, sparing justAdded: Set<ObjectIdentifier>) -> Int {
        var hidden = 0
        let ownMeshes = Set(host.composition?.snapshot.meshes.map { ObjectIdentifier($0) } ?? [])
        for (meshIndex, mesh) in host.meshes.enumerated() where !justAdded.contains(ObjectIdentifier(mesh)) {
            for primitive in mesh.primitives {
                guard let material = primitive.materialIndex, material < host.materials.count,
                    kind.slots.contains(host.slot(ofMaterial: material))
                else { continue }
                if guardsHead(kind, slot: host.slot(ofMaterial: material)), ownMeshes.contains(ObjectIdentifier(mesh)),
                    keepHead(of: primitive, node: host.nodes.first { $0.mesh == meshIndex }, host: host) != .hide {
                    continue
                }
                host.hiddenPrimitives.insert(ObjectIdentifier(primitive))
                hidden += 1
            }
        }
        return hidden
    }

    /// The joint slots of `skin` that are the head bone or ride it.
    static func headJoints(of skin: VRMSkin, in model: VRMModel) -> Set<Int> {
        guard let head = headNode(of: model) else { return [] }
        var slots = Set<Int>()
        for (slot, joint) in skin.joints.enumerated() where isOnHead(joint, head: head) { slots.insert(slot) }
        return slots
    }

    /// Whether a mesh node hangs off the head (an unskinned accessory
    /// parented to it).
    static func ridesHead(_ node: VRMNode, in model: VRMModel) -> Bool {
        guard let head = headNode(of: model) else { return false }
        return isOnHead(node, head: head)
    }

    private static func headNode(of model: VRMModel) -> VRMNode? {
        guard let index = model.humanoid?.getBoneNode(.head), index < model.nodes.count else { return nil }
        return model.nodes[index]
    }

    private static func isOnHead(_ node: VRMNode, head: VRMNode) -> Bool {
        var current: VRMNode? = node
        while let step = current {
            if step === head { return true }
            current = step.parent
        }
        return false
    }

    /// The donor primitive an outfit graft brings: itself when nothing of
    /// it rides the head, a clone without its head triangles when some
    /// does, nil when all of it does (glasses, a hairpin).
    static func belowTheHead(
        _ primitive: VRMPrimitive, node: VRMNode, donor: VRMModel, device: MTLDevice?
    ) -> VRMPrimitive? {
        guard let skinIndex = node.skin, skinIndex < donor.skins.count else {
            return ridesHead(node, in: donor) ? nil : primitive
        }
        let joints = headJoints(of: donor.skins[skinIndex], in: donor)
        guard !joints.isEmpty, let device, let split = primitive.splitAtHead(device: device, headJoints: joints)
        else { return primitive }
        if split.head.isEmpty { return primitive }
        guard split.rest.count >= 3, let buffer = split.rest.buffer else { return nil }
        let clone = primitive.shallowClone()
        clone.indexBuffer = buffer
        clone.indexCount = split.rest.count
        clone.indexBufferOffset = 0
        return clone
    }

    /// What happens to a host primitive in the outfit's slots.
    enum HostHeadOutcome {
        /// Nothing of it is on the head: hide it, as before.
        case hide
        /// Narrowed in place to its head triangles, which stay visible.
        case keptHead
        /// All of it is on the head: left alone.
        case untouched
    }

    /// Keeps the head triangles of one of the host's own primitives while
    /// the rest of it makes way for the outfit. The narrowing is a trim
    /// (`untrimmedIndices`), so `restoreBaseComposition` undoes it.
    static func keepHead(of primitive: VRMPrimitive, node: VRMNode?, host: VRMModel) -> HostHeadOutcome {
        guard let node else { return .hide }
        guard let skinIndex = node.skin, skinIndex < host.skins.count else {
            return ridesHead(node, in: host) ? .untouched : .hide
        }
        let joints = headJoints(of: host.skins[skinIndex], in: host)
        guard !joints.isEmpty, primitive.untrimmedIndices == nil, let device = host.device,
            let split = primitive.splitAtHead(device: device, headJoints: joints), split.head.count >= 3
        else { return .hide }
        if split.rest.isEmpty { return .untouched }
        guard let buffer = split.head.buffer else { return .hide }
        primitive.untrimmedIndices = VRMPrimitive.UntrimmedIndices(
            buffer: primitive.indexBuffer, count: primitive.indexCount, offset: primitive.indexBufferOffset)
        primitive.indexBuffer = buffer
        primitive.indexCount = split.head.count
        primitive.indexBufferOffset = 0
        return .keptHead
    }
}

extension VRMPrimitive {

    /// One side of a split: an index buffer of the same index type (nil
    /// when the side is empty) and how many indices it holds.
    struct IndexSlice {
        let buffer: MTLBuffer?
        let count: Int
        var isEmpty: Bool { count < 3 }
    }

    /// Sorts this primitive's triangles into those that ride the head —
    /// the strongest joint of all three corners is in `headJoints` — and
    /// the rest. Nil when the buffers cannot be read (unskinned, private
    /// storage, not a triangle list).
    func splitAtHead(device: MTLDevice, headJoints: Set<Int>) -> (head: IndexSlice, rest: IndexSlice)? {
        guard primitiveType == .triangle, hasJoints,
            let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.joints),
            let weightsOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.weights),
            let vertexBuffer, vertexBuffer.storageMode == .shared,
            let indexBuffer, indexBuffer.storageMode == .shared,
            indexCount >= 3, vertexCount > 0,
            vertexBuffer.length >= vertexCount * MemoryLayout<VRMVertex>.stride
        else { return nil }
        let stride = MemoryLayout<VRMVertex>.stride
        let vertexBase = vertexBuffer.contents()
        let indexBase = indexBuffer.contents().advanced(by: indexBufferOffset)
        let wide = indexType == .uint32

        // Each vertex is judged once; a VRoid body shares one vertex array.
        var verdicts: [Int: Bool] = [:]
        func onHead(_ vertex: Int) -> Bool {
            if let known = verdicts[vertex] { return known }
            var verdict = false
            if vertex < vertexCount {
                let joints = vertexBase.load(fromByteOffset: vertex * stride + jointsOffset, as: SIMD4<UInt32>.self)
                let weights = vertexBase.load(fromByteOffset: vertex * stride + weightsOffset, as: SIMD4<Float>.self)
                var strongest = 0
                for slot in 1..<4 where weights[slot] > weights[strongest] { strongest = slot }
                verdict = weights[strongest] > 0 && headJoints.contains(Int(joints[strongest]))
            }
            verdicts[vertex] = verdict
            return verdict
        }
        func index(_ position: Int) -> Int {
            wide
                ? Int(indexBase.load(fromByteOffset: position * 4, as: UInt32.self))
                : Int(indexBase.load(fromByteOffset: position * 2, as: UInt16.self))
        }

        var head: [Int] = []
        var rest: [Int] = []
        for triangle in Swift.stride(from: 0, to: indexCount - 2, by: 3) {
            let corners = [index(triangle), index(triangle + 1), index(triangle + 2)]
            if corners.allSatisfy(onHead) { head += corners } else { rest += corners }
        }
        func slice(_ indices: [Int]) -> IndexSlice {
            guard !indices.isEmpty else { return IndexSlice(buffer: nil, count: 0) }
            let buffer: MTLBuffer? = wide
                ? indices.map(UInt32.init).withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
                : indices.map(UInt16.init).withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
            return IndexSlice(buffer: buffer, count: indices.count)
        }
        return (slice(head), slice(rest))
    }
}
