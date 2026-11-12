//
//  VRMModel+SceneProps.swift
//  NeuraLink
//
//  Rigid props standing in the world rather than in a hand (the keepsake
//  table and what is on it): root-level runtime nodes drawn by the
//  renderer's rigid path along with the character, so they share its
//  lighting, shadow map and draw list. A placement is given in world
//  metres; the node carries it in the model's own frame (the renderer
//  yaws a VRM 0.x model 180°, so its nodes are pre-yawed back). Hidden
//  means `node.mesh == nil`, as for hand props, and a composition restore
//  re-appends them (`reattachProps`). The figure's heel lift leaves them
//  on the floor (VRMPartGrafter.raiseFigure).
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import simd

/// One prop standing in the scene on one model.
public final class VRMScenePlacement {
    public let prop: VRMProp
    /// Where it stands, in world metres.
    internal(set) var world: RestTransform
    public internal(set) var nodes: [VRMNode] = []
    public internal(set) var meshes: [VRMMesh] = []
    var meshIndices: [Int] = []
    public internal(set) var isVisible: Bool

    init(prop: VRMProp, world: RestTransform, visible: Bool) {
        self.prop = prop
        self.world = world
        self.isVisible = visible
    }
}

extension VRMModel {

    /// Stands `prop` at `world`. The renderer's item list must be rebuilt
    /// afterwards (`VRMRenderer.invalidateRenderItems()`).
    @discardableResult
    func placeProp(_ prop: VRMProp, at world: RestTransform, visible: Bool = true) -> VRMScenePlacement {
        let placement = VRMScenePlacement(prop: prop, world: world, visible: visible)
        withLock {
            appendSceneNodes(for: placement)
            sceneProps.append(placement)
        }
        return placement
    }

    /// Moves a standing prop (the table follows the environment).
    func moveSceneProp(_ placement: VRMScenePlacement, to world: RestTransform) {
        withLock {
            placement.world = world
            let base = Self.modelSpace(world, isVRM0: isVRM0)
            for (node, part) in zip(placement.nodes, placement.prop.parts) {
                let transform = Self.compose(base, part.chain)
                node.translation = transform.translation
                node.rotation = transform.rotation
                node.scale = transform.scale
                node.updateLocalMatrix()
                node.updateWorldTransform()
            }
        }
    }

    func setSceneProp(_ placement: VRMScenePlacement, visible: Bool) {
        withLock {
            placement.isVisible = visible
            for (node, meshIndex) in zip(placement.nodes, placement.meshIndices) {
                node.mesh = visible ? meshIndex : nil
            }
        }
    }

    /// Takes a prop off the scene: hidden now and not re-appended by a
    /// restore. Its nodes stay (hidden) until the model goes.
    func removeSceneProp(_ placement: VRMScenePlacement) {
        setSceneProp(placement, visible: false)
        withLock { sceneProps.removeAll { $0 === placement } }
    }

    /// Nodes that belong to standing props — not part of the figure.
    var scenePropNodeIDs: Set<ObjectIdentifier> {
        Set(sceneProps.flatMap { $0.nodes.map { ObjectIdentifier($0) } })
    }

    /// After `restoreBaseComposition`: placements made after the snapshot
    /// were truncated away with the grafts; put them back where they were.
    func reattachSceneProps() {
        for placement in sceneProps {
            let stillAttached = !placement.nodes.isEmpty
                && placement.nodes.allSatisfy { node in nodes.contains { $0 === node } }
            guard !stillAttached else { continue }
            appendSceneNodes(for: placement)
        }
    }

    /// The node transform that puts `world` on screen: the renderer applies
    /// `vrmVersionRotation` (a 180° yaw for VRM 0.x) to every item, so a
    /// 0.x node is pre-yawed back.
    static func modelSpace(_ world: RestTransform, isVRM0: Bool) -> RestTransform {
        guard isVRM0 else { return world }
        let yawInverse = vrmVersionYaw.inverse
        return RestTransform(
            rotation: simd_normalize(yawInverse * world.rotation),
            translation: yawInverse.act(world.translation),
            scale: world.scale)
    }

    /// outer ∘ inner, as a node chain composes.
    static func compose(_ outer: RestTransform, _ inner: RestTransform) -> RestTransform {
        RestTransform(
            rotation: simd_normalize(outer.rotation * inner.rotation),
            translation: outer.translation + outer.rotation.act(outer.scale * inner.translation),
            scale: outer.scale * inner.scale)
    }

    /// Appends the prop's textures, materials (copied, with their texture
    /// indices moved to this model's array), meshes and one root node per
    /// part. Caller holds the lock.
    private func appendSceneNodes(for placement: VRMScenePlacement) {
        placement.nodes.removeAll()
        placement.meshes.removeAll()
        placement.meshIndices.removeAll()
        let textureBase = textures.count
        let materialBase = materials.count
        textures.append(contentsOf: placement.prop.textures)
        for material in placement.prop.materials {
            let copy = VRMMaterial(copying: material)
            if let index = copy.mtoon?.shadeMultiplyTexture { copy.mtoon?.shadeMultiplyTexture = index + textureBase }
            materials.append(copy)
        }
        let base = Self.modelSpace(placement.world, isVRM0: isVRM0)
        for part in placement.prop.parts {
            let mesh = VRMMesh(name: part.mesh.name)
            for primitive in part.mesh.primitives {
                let clone = primitive.shallowClone()
                if let index = primitive.materialIndex { clone.materialIndex = materialBase + index }
                mesh.primitives.append(clone)
            }
            meshes.append(mesh)
            let meshIndex = meshes.count - 1
            let transform = Self.compose(base, part.chain)
            let node = VRMNode(
                index: nodes.count, name: "\(placement.prop.name)_scene",
                translation: transform.translation, rotation: transform.rotation, scale: transform.scale,
                mesh: placement.isVisible ? meshIndex : nil)
            nodes.append(node)
            placement.nodes.append(node)
            placement.meshes.append(mesh)
            placement.meshIndices.append(meshIndex)
        }
        buildNodeLookupTable()
        updateNodeTransforms()
    }
}
