//
//  VRMModel+Props.swift
//  NeuraLink
//
//  Attaching a `VRMProp` to a humanoid bone. The prop's meshes, materials
//  and textures are appended to the model's plain arrays (as part grafts
//  do, GPU buffers shared) and one runtime node per part hangs under the
//  bone with the grip and the file's node chain as its local transform.
//  Hidden means `node.mesh == nil`: both the main pass's render items and
//  the shadow pass key off that, where `hiddenPrimitives` only reaches the
//  former. A composition restore truncates the arrays back to the base
//  snapshot, so props attached after that snapshot are re-appended.
//
//  Created by Dedicatus on 06/10/2026.
//

import Foundation
import simd

/// One prop on one model. Nodes and mesh indices are rebuilt on restore.
public final class VRMPropAttachment {
    public let prop: VRMProp
    public let bone: VRMHumanoidBone
    public let grip: VRMPropGrip
    public internal(set) var nodes: [VRMNode] = []
    public internal(set) var meshes: [VRMMesh] = []
    var meshIndices: [Int] = []
    public internal(set) var isVisible = false
    /// The grip carried onto this rig (palm or hand-bone), before any seat.
    public internal(set) var baseGrip: VRMPropGrip?
    /// The grip in the bone's own local frame, as last seated.
    public internal(set) var handGrip: VRMPropGrip?
    /// The outfit the current seat was fitted for (nil: not fitted).
    var seatedFor: String?

    init(prop: VRMProp, bone: VRMHumanoidBone, grip: VRMPropGrip) {
        self.prop = prop
        self.bone = bone
        self.grip = grip
    }
}

extension VRMModel {

    /// Hangs `prop` under `bone`, hidden. Throws when the rig has no such
    /// bone. Call before the first graft when possible so the prop is part
    /// of the composition snapshot; otherwise it is re-attached on restore.
    @discardableResult
    public func attachProp(_ prop: VRMProp, to bone: VRMHumanoidBone, grip: VRMPropGrip) throws -> VRMPropAttachment {
        guard let humanoid, let boneIndex = humanoid.getBoneNode(bone), boneIndex < nodes.count else {
            throw VRMPropError.missingBone(bone)
        }
        let attachment = VRMPropAttachment(prop: prop, bone: bone, grip: grip)
        withLock {
            append(attachment, under: nodes[boneIndex])
            props.append(attachment)
        }
        return attachment
    }

    /// Shows or hides the prop. The renderer's item list must be rebuilt
    /// afterwards (`VRMRenderer.invalidateRenderItems()`).
    public func setProp(_ attachment: VRMPropAttachment, visible: Bool) {
        withLock {
            attachment.isVisible = visible
            for (node, meshIndex) in zip(attachment.nodes, attachment.meshIndices) {
                node.mesh = visible ? meshIndex : nil
            }
        }
    }

    /// Moves the prop to `handGrip` (in the bone's local frame) without
    /// re-attaching it — a seat refined against the drawn hand.
    public func reseat(_ attachment: VRMPropAttachment, handGrip: VRMPropGrip) {
        withLock {
            attachment.handGrip = handGrip
            for (node, part) in zip(attachment.nodes, attachment.prop.parts) {
                let transform = Self.nodeTransform(of: part, in: handGrip)
                node.translation = transform.translation
                node.rotation = transform.rotation
                node.scale = transform.scale
                node.updateLocalMatrix()
                node.updateWorldTransform()
            }
        }
    }

    /// local = grip ∘ chain, so the file's own scale and turn ride along and
    /// the grip is authored for a life-size, upright prop.
    private static func nodeTransform(of part: VRMProp.Part, in grip: VRMPropGrip) -> RestTransform {
        RestTransform(
            rotation: simd_normalize(grip.rotation * part.chain.rotation),
            translation: grip.translation + grip.rotation.act(part.chain.translation * grip.scale),
            scale: part.chain.scale * grip.scale)
    }

    /// Seats the prop against the hand that is drawn (VRMPropSeat), with the
    /// hand's fingers posed as `holding` — the clip's hold frame, applied for
    /// the measurement only. Once per outfit; free when nothing changed.
    public func seatProp(_ attachment: VRMPropAttachment, holding: [VRMHumanoidBone: simd_quatf]) {
        let outfit = propSeatKey
        guard attachment.seatedFor != outfit, let base = attachment.baseGrip,
              let box = VRMPropSeat.box(of: attachment.prop),
              let handIndex = humanoid?.getBoneNode(attachment.bone), let hand = nodes[safe: handIndex]
        else { return }
        let points: [SIMD3<Float>] = withLock {
            var saved: [(VRMNode, simd_quatf)] = []
            for (bone, rotation) in holding {
                guard let index = humanoid?.getBoneNode(bone), let node = nodes[safe: index] else { continue }
                saved.append((node, node.rotation))
                node.rotation = rotation
                node.updateLocalMatrix()
            }
            hand.updateWorldTransform()
            let points = VRMPropSeat.handPoints(in: self, hand: attachment.bone)
            for (node, rotation) in saved {
                node.rotation = rotation
                node.updateLocalMatrix()
            }
            hand.updateWorldTransform()
            return points
        }
        let seated = VRMPropSeat(points: points, box: box).fit(from: base)
        reseat(attachment, handGrip: seated)
        attachment.seatedFor = outfit
    }

    /// Identifies the drawn outfit (the grafted parts), which is what
    /// decides the hands a prop is seated against.
    var propSeatKey: String {
        (composition?.activeParts ?? [:]).map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ",")
    }

    /// Meshes that belong to props — `calculateBoundingBox` skips them: the
    /// vertices are in the file's units (centimetres for the phone) and
    /// would inflate the figure's box to tens of metres.
    var propMeshIDs: Set<ObjectIdentifier> {
        Set(props.flatMap { $0.meshes.map { ObjectIdentifier($0) } })
    }

    /// After `restoreBaseComposition`: props attached after the snapshot
    /// were truncated away with the grafts; put them back as they were.
    func reattachProps() {
        for attachment in props {
            let stillAttached = !attachment.nodes.isEmpty
                && attachment.nodes.allSatisfy { node in nodes.contains { $0 === node } }
            guard !stillAttached,
                let humanoid, let boneIndex = humanoid.getBoneNode(attachment.bone), boneIndex < nodes.count
            else { continue }
            append(attachment, under: nodes[boneIndex])
        }
    }

    /// World rest rotation of a node: its bind-pose rotations composed from
    /// the root down (identity on every VRoid humanoid bone).
    private func restWorldRotation(of node: VRMNode) -> simd_quatf {
        var rotation = node.initialRotation
        var ancestor = node.parent
        while let parent = ancestor {
            rotation = parent.initialRotation * rotation
            ancestor = parent.parent
        }
        return simd_normalize(rotation)
    }

    /// The grip in `bone`'s own local frame. A grip tuned on a measured palm
    /// moves onto this rig's palm (same seat, scaled to the hand). Otherwise
    /// it is an offset in the world-aligned T-pose hand frame: a VRoid hand
    /// has an identity rest rotation, so that IS its local frame; a rig with
    /// a baked rest rotation needs the grip brought into its frame first.
    private func handLocalGrip(for attachment: VRMPropAttachment, under bone: VRMNode) -> VRMPropGrip {
        if let reference = attachment.grip.authoredOn,
           let palm = VRMPalm.measure(in: self, hand: attachment.bone) {
            return palm.place(attachment.grip, authoredOn: reference)
        }
        let resolved = attachment.grip.resolved(forVRM0: isVRM0)
        let restInverse = restWorldRotation(of: bone).inverse
        return VRMPropGrip(
            translation: restInverse.act(resolved.translation),
            rotation: simd_normalize(restInverse * resolved.rotation),
            scale: resolved.scale)
    }

    private func append(_ attachment: VRMPropAttachment, under bone: VRMNode) {
        attachment.nodes.removeAll()
        attachment.meshes.removeAll()
        attachment.meshIndices.removeAll()
        let materialBase = materials.count
        textures.append(contentsOf: attachment.prop.textures)
        materials.append(contentsOf: attachment.prop.materials)
        // Fresh from the grip on every (re)attach; a seat fitted to the
        // previous outfit's hands no longer applies.
        let grip = handLocalGrip(for: attachment, under: bone)
        attachment.baseGrip = grip
        attachment.handGrip = grip
        attachment.seatedFor = nil
        for part in attachment.prop.parts {
            let mesh = VRMMesh(name: part.mesh.name)
            for primitive in part.mesh.primitives {
                let clone = primitive.shallowClone()
                if let index = primitive.materialIndex { clone.materialIndex = materialBase + index }
                mesh.primitives.append(clone)
            }
            meshes.append(mesh)
            let meshIndex = meshes.count - 1
            let transform = Self.nodeTransform(of: part, in: grip)
            let node = VRMNode(
                index: nodes.count, name: "\(attachment.prop.name)_prop",
                translation: transform.translation, rotation: transform.rotation, scale: transform.scale,
                mesh: attachment.isVisible ? meshIndex : nil)
            nodes.append(node)
            node.parent = bone
            bone.children.append(node)
            attachment.nodes.append(node)
            attachment.meshes.append(mesh)
            attachment.meshIndices.append(meshIndex)
        }
        buildNodeLookupTable()
        updateNodeTransforms()
    }
}
