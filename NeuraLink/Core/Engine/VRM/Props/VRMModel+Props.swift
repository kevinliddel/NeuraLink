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

    private func append(_ attachment: VRMPropAttachment, under bone: VRMNode) {
        attachment.nodes.removeAll()
        attachment.meshes.removeAll()
        attachment.meshIndices.removeAll()
        let materialBase = materials.count
        textures.append(contentsOf: attachment.prop.textures)
        materials.append(contentsOf: attachment.prop.materials)
        // The grip is authored in the world-aligned T-pose hand frame. A
        // VRoid hand has an identity rest rotation, so that IS its local
        // frame; a rig with a baked rest rotation (some imported models)
        // needs the grip brought into its local frame first.
        let resolved = attachment.grip.resolved(forVRM0: isVRM0)
        let restInverse = restWorldRotation(of: bone).inverse
        let grip = VRMPropGrip(
            translation: restInverse.act(resolved.translation),
            rotation: simd_normalize(restInverse * resolved.rotation),
            scale: resolved.scale)
        for part in attachment.prop.parts {
            let mesh = VRMMesh(name: part.mesh.name)
            for primitive in part.mesh.primitives {
                let clone = primitive.shallowClone()
                if let index = primitive.materialIndex { clone.materialIndex = materialBase + index }
                mesh.primitives.append(clone)
            }
            meshes.append(mesh)
            let meshIndex = meshes.count - 1
            // local = grip ∘ chain, so the file's own scale and turn ride
            // along and the grip is authored for a life-size, upright prop.
            let node = VRMNode(
                index: nodes.count, name: "\(attachment.prop.name)_prop",
                translation: grip.translation + grip.rotation.act(part.chain.translation * grip.scale),
                rotation: simd_normalize(grip.rotation * part.chain.rotation),
                scale: part.chain.scale * grip.scale,
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
