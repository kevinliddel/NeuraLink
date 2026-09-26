//
//  VRMModel+Composition.swift
//  NeuraLink
//
//  Base-model snapshot + restore for part grafts (Tier B of
//  docs/CHARACTER_CUSTOMIZATION_PLAN.md). A graft only ever APPENDS to the
//  model's arrays and hides host primitives, so "undo everything" is
//  truncating back to the snapshot and dropping the appended children off
//  the host bones. Changing one part = restore + re-graft all active parts,
//  which keeps the bookkeeping trivial and order-independent.
//

import Foundation
import simd

/// Snapshot of the un-grafted model plus the grafts currently applied.
public final class VRMCompositionState {
    struct Snapshot {
        let meshes: [VRMMesh]
        let materials: [VRMMaterial]
        let textures: [VRMTexture]
        let nodes: [VRMNode]
        let skins: [VRMSkin]
        let springBone: VRMSpringBone?
        /// Children of every base node at snapshot time (identity-keyed).
        let childrenByNode: [ObjectIdentifier: [VRMNode]]
        let baseNodeIDs: Set<ObjectIdentifier>

        func isBaseNode(_ node: VRMNode) -> Bool { baseNodeIDs.contains(ObjectIdentifier(node)) }
    }

    let snapshot: Snapshot
    public internal(set) var grafts: [GraftReceipt] = []

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    public var activeParts: [AppearancePartKind: String] {
        Dictionary(uniqueKeysWithValues: grafts.map { ($0.kind, $0.donorSlug) })
    }
}

/// What one graft added to the host. Purely informational — undo goes
/// through the snapshot.
public struct GraftReceipt: Sendable {
    public let kind: AppearancePartKind
    public let donorSlug: String
    public let meshCount: Int
    public let materialCount: Int
    public let textureCount: Int
    public let nodeCount: Int
    public let skinCount: Int
    public let springCount: Int
    public let hiddenPrimitiveCount: Int
}

extension VRMModel {

    /// Captures the base composition once. Idempotent.
    public func beginComposition() {
        guard composition == nil else { return }
        var children: [ObjectIdentifier: [VRMNode]] = [:]
        for node in nodes { children[ObjectIdentifier(node)] = node.children }
        composition = VRMCompositionState(snapshot: .init(
            meshes: meshes, materials: materials, textures: textures, nodes: nodes, skins: skins,
            springBone: springBone, childrenByNode: children,
            baseNodeIDs: Set(nodes.map { ObjectIdentifier($0) })))
    }

    /// Drops every graft: arrays back to the snapshot, appended bones
    /// detached from their host parents, hidden primitives shown again.
    public func restoreBaseComposition() {
        guard let composition else { return }
        let snap = composition.snapshot
        meshes = snap.meshes
        materials = snap.materials
        textures = snap.textures
        skins = snap.skins
        springBone = snap.springBone
        for node in snap.nodes {
            if let original = snap.childrenByNode[ObjectIdentifier(node)] {
                node.children = original
            }
        }
        nodes = snap.nodes
        hiddenPrimitives.removeAll()
        composition.grafts.removeAll()
        buildNodeLookupTable()
        updateNodeTransforms()
    }

    /// True when any part is currently grafted.
    public var hasGrafts: Bool {
        !(composition?.grafts.isEmpty ?? true)
    }

    /// False for nodes appended by a graft (true when no snapshot exists).
    func isBaseNode(_ node: VRMNode) -> Bool {
        composition?.snapshot.isBaseNode(node) ?? true
    }

    // MARK: - Helpers shared with the grafter

    /// Host node for a donor bone name, or nil when the bone must be
    /// appended. Only humanoid bones and VRoid's `J_Adj_*` helper bones bind
    /// by name: secondary bones (`J_Sec_*`, `HairJoint-*`) share names
    /// between VRoid models but are different bones, so they always come
    /// with the part.
    func compositionBindTarget(forDonorBoneNamed name: String?) -> VRMNode? {
        guard let name, !name.isEmpty else { return nil }
        guard let node = nodes.first(where: { $0.name == name }) else { return nil }
        if name.hasPrefix("J_Adj_") { return node }
        guard let humanoid else { return nil }
        let humanoidNodes = Set(humanoid.humanBones.values.map(\.node))
        return humanoidNodes.contains(node.index) ? node : nil
    }

    /// The 180° yaw the renderer applies to VRM 0.x models
    /// (`VRMRenderer.vrmVersionRotation`). A part crossing spec versions is
    /// conjugated by this so it lands in the host's convention.
    static let vrmVersionYaw = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
}
