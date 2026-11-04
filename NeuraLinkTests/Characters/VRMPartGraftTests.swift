//
//  VRMPartGraftTests.swift
//  NeuraLinkTests
//
//  Part grafting (Tier B): Sonya's hair / outfit onto Ekaterina. The pair
//  crosses spec versions (Ekaterina VRM 0.x, Sonya VRM 1.0), so the yaw
//  conjugation path is exercised too. Pins the invariants the renderer
//  relies on — every appended bone is parented, every spring joint index
//  is in range, joints per skin stay ≤ 255 — and that restore is exact.
//

import Testing
import Foundation
import Metal
@testable import NeuraLink

@Suite("VRM part grafts", .serialized)
struct VRMPartGraftTests {

    private func loadPair() async throws -> (host: VRMModel, donor: VRMModel)? {
        guard let device = MTLCreateSystemDefaultDevice(),
            let ekaterina = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm"),
            let sonya = Bundle.main.url(forResource: "Sonya", withExtension: "vrm")
        else {
            Issue.record("Metal device or bundled VRMs unavailable")
            return nil
        }
        let host = try await VRMModel.load(from: ekaterina, device: device)
        let donor = try await VRMModel.load(from: sonya, device: device)
        return (host, donor)
    }

    private struct Counts: Equatable {
        let meshes: Int, materials: Int, textures: Int, nodes: Int, skins: Int, springs: Int, hidden: Int
        init(_ m: VRMModel) {
            meshes = m.meshes.count; materials = m.materials.count; textures = m.textures.count
            nodes = m.nodes.count; skins = m.skins.count
            springs = m.springBone?.springs.count ?? 0; hidden = m.hiddenPrimitives.count
        }
    }

    private func checkInvariants(_ model: VRMModel, appendedFrom baseNodeCount: Int) {
        // Mesh nodes are scene roots (like the donor's); every appended BONE
        // must hang off a parent that lists it.
        for node in model.nodes[baseNodeCount...] where node.mesh == nil {
            #expect(node.parent != nil, "appended node '\(node.name ?? "?")' has a parent")
            #expect(node.parent?.children.contains { $0 === node } == true, "parent lists appended child")
        }
        for skin in model.skins {
            #expect(skin.joints.count == skin.inverseBindMatrices.count)
            #expect(skin.joints.count <= 255, "palette fits the shader's clamp")
            for joint in skin.joints { #expect(model.nodes.contains { $0 === joint }, "skin joint is a host node") }
        }
        for spring in model.springBone?.springs ?? [] {
            for joint in spring.joints { #expect(joint.node < model.nodes.count) }
            for group in spring.colliderGroups { #expect(group < (model.springBone?.colliderGroups.count ?? 0)) }
        }
        for collider in model.springBone?.colliders ?? [] { #expect(collider.node < model.nodes.count) }
    }

    @Test("Hair graft appends bones + springs, hides host hair, and restores exactly")
    func hairGraftAndRestore() async throws {
        guard let (host, donor) = try await loadPair() else { return }
        let base = Counts(host)
        #expect(host.isVRM0 && !donor.isVRM0, "pair crosses spec versions")

        let receipt = try VRMPartGrafter.graft(.hair, from: donor, donorSlug: "sonya", onto: host)
        let after = Counts(host)
        #expect(receipt.meshCount >= 1)
        #expect(after.meshes == base.meshes + receipt.meshCount)
        #expect(after.nodes > base.nodes, "hair chain bones were appended")
        #expect(after.skins == base.skins + receipt.skinCount)
        #expect(after.springs > base.springs, "donor hair springs came along")
        #expect(after.hidden >= 2, "host hair + back-hair primitives hidden")
        #expect(host.hasGrafts)
        #expect(host.composition?.activeParts == [.hair: "sonya"])
        checkInvariants(host, appendedFrom: base.nodes)

        // Every appended bone ultimately hangs off the host head.
        let headIndex = try #require(host.humanoid?.getBoneNode(.head))
        let head = host.nodes[headIndex]
        for node in host.nodes[base.nodes...] where node.mesh == nil {
            var cursor: VRMNode? = node
            var reachesHead = false
            while let c = cursor { if c === head { reachesHead = true; break }; cursor = c.parent }
            #expect(reachesHead, "'\(node.name ?? "?")' is under the host head")
        }

        host.restoreBaseComposition()
        #expect(Counts(host) == base, "restore is exact")
        #expect(!host.hasGrafts)
        #expect(head.children.allSatisfy { child in host.nodes.contains { $0 === child } }, "appended children detached")
    }

    @Test("Outfit graft swaps body + clothes and can coexist with hair")
    func outfitGraft() async throws {
        guard let (host, donor) = try await loadPair() else { return }
        let base = Counts(host)
        try VRMPartGrafter.graft(.hair, from: donor, donorSlug: "sonya", onto: host)
        let receipt = try VRMPartGrafter.graft(.outfit, from: donor, donorSlug: "sonya", onto: host)
        #expect(receipt.hiddenPrimitiveCount >= 2, "host body skin + clothing hidden")
        #expect(host.composition?.activeParts == [.hair: "sonya", .outfit: "sonya"])
        checkInvariants(host, appendedFrom: base.nodes)

        // Grafted materials classify into the outfit's slots and nothing else.
        let grafted = host.materials[base.materials...]
        let slots = Set(grafted.map { VRoidMaterialSlot.classify(materialName: $0.name) })
        #expect(slots.isSubset(of: AppearancePartKind.hair.slots.union(AppearancePartKind.outfit.slots)))

        host.restoreBaseComposition()
        #expect(Counts(host) == base)
    }

    @Test("Grafting a part the donor lacks throws")
    func missingPart() async throws {
        guard let (host, _) = try await loadPair() else { return }
        // A model with no clothing/hair materials: build one by hiding — use
        // the host itself as a donor whose slots are filtered to nothing.
        let empty = host
        empty.materials = []
        #expect(throws: VRMPartGraftError.self) {
            try VRMPartGrafter.graft(.hair, from: empty, donorSlug: "x", onto: empty)
        }
    }
}
