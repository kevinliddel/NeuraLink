//
//  ShoeGraftTests.swift
//  NeuraLinkTests
//
//  A borrowed shoe is rigid on the foot and brings the foot it was
//  modelled around. Bundled characters only, so nothing is downloaded:
//  Sonya (VRM 1.0) lends her shoes to Ekaterina (VRM 0.x), whose rig puts
//  the toes and shin in different places relative to the ankle.
//
//  Created by Dedicatus on 26/10/2026.
//

import Testing
import Foundation
import Metal
import simd
@testable import NeuraLink

@Suite("Shoe graft", .serialized)
struct ShoeGraftTests {

    @MainActor
    private func pair() async throws -> (host: VRMModel, donor: VRMModel)? {
        guard let device = MTLCreateSystemDefaultDevice(),
            let hostURL = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm"),
            let donorURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm")
        else { return nil }
        let host = try await VRMModel.load(from: hostURL, device: device)
        let donor = try await VRMModel.load(from: donorURL, device: device)
        host.beginComposition()
        return (host, donor)
    }

    @Test("Toe box, collar and straps are bound where the foot puts them")
    @MainActor
    func followersSitOnTheAnchor() async throws {
        guard let (host, donor) = try await pair() else { return }
        let baseSkins = host.skins.count
        try VRMPartGrafter.graft(.shoes, from: donor, donorSlug: "sonya", onto: host)

        // Kept as the donor bound them, the toe- and shin-weighted parts
        // hung off the HOST's toe and knee joints at the donor's distances
        // from them, and the shoe came apart wherever those differ.
        var checked = 0
        for skin in host.skins.dropFirst(baseSkins) {
            for (anchor, follower) in AppearancePartKind.shoes.anchorFollowers {
                guard let anchorIndex = host.humanoid?.getBoneNode(anchor),
                    let followerIndex = host.humanoid?.getBoneNode(follower),
                    let a = skin.joints.firstIndex(where: { $0 === host.nodes[anchorIndex] }),
                    let f = skin.joints.firstIndex(where: { $0 === host.nodes[followerIndex] }),
                    let anchorBind = host.bindMatrix(of: anchor),
                    let followerBind = host.bindMatrix(of: follower)
                else { continue }
                let byAnchor = anchorBind * skin.inverseBindMatrices[a]
                let byFollower = followerBind * skin.inverseBindMatrices[f]
                var worst: Float = 0
                for column in 0..<4 {
                    worst = max(worst, simd_reduce_max(simd_abs(byAnchor[column] - byFollower[column])))
                }
                #expect(worst < 1e-4, "\(follower) places the shoe where \(anchor) does: off by \(worst)")
                checked += 1
            }
        }
        #expect(checked >= 4, "toes and shin on both feet")
    }

    @Test("A borrowed shoe brings the foot it was modelled around, in the host's skin")
    @MainActor
    func shoeBringsItsFoot() async throws {
        guard let (host, donor) = try await pair() else { return }
        // Her body: the largest body-skin primitive.
        let hostSkin = host.meshes.flatMap(\.primitives)
            .filter { $0.materialIndex.map { host.slot(ofMaterial: $0) == .bodySkin } ?? false }
            .max { $0.indexCount < $1.indexCount }?.materialIndex
        // Gathered before the graft trims her own foot away.
        let hostAnkle = try #require(host.bindPosition(of: .leftFoot)).y
        var hostFootUVs = Set<SIMD2<Float>>()
        for primitive in host.meshes.flatMap(\.primitives) where primitive.materialIndex == hostSkin {
            primitive.forEachVertex { if $0.position.y < hostAnkle + 0.04 { hostFootUVs.insert($0.texCoord) } }
        }
        let baseMeshes = host.meshes.count
        try VRMPartGrafter.graft(.shoes, from: donor, donorSlug: "sonya", onto: host)

        let feet = host.meshes.dropFirst(baseMeshes).flatMap(\.primitives).filter {
            $0.materialIndex.map { host.slot(ofMaterial: $0) == .bodySkin } ?? false
        }
        #expect(!feet.isEmpty, "the donor's foot came with the shoe")
        // Her skin material, drawn from both sides so an open rim reads as
        // skin rather than the inside of an outline.
        let own = try #require(hostSkin.map { host.materials[$0] })
        #expect(feet.allSatisfy { foot in
            guard let index = foot.materialIndex else { return false }
            let material = host.materials[index]
            return material.baseColorTexture === own.baseColorTexture && material.doubleSided
                && host.slot(ofMaterial: index) == .bodySkin
        }, "drawn with Ekaterina's own skin")
        // Sonya's body is unwrapped differently from Ekaterina's: read with
        // its own UVs, the borrowed instep landed off Ekaterina's foot in
        // her texture and drew dark patches. Every UV has to be one of hers.
        var footUVs = Set<SIMD2<Float>>()
        for foot in feet { foot.forEachVertex { footUVs.insert($0.texCoord) } }
        #expect(!footUVs.isEmpty && footUVs.isSubset(of: hostFootUVs),
                "\(footUVs.subtracting(hostFootUVs).count) of \(footUVs.count) UVs are not Ekaterina's foot")

        // The foot and nothing more: no leg, no hands.
        let ankle = try #require(donor.bindPosition(of: .leftFoot)).y
        let top = feet.compactMap { $0.restHeightRange()?.max }.max() ?? .infinity
        #expect(top < ankle + 0.03, "skin stops at the ankle: \(top) vs \(ankle)")

        // Toes and all: the borrowed skin reaches the front of the shoe.
        let forward: Float = donor.isVRM0 ? -1 : 1
        var footFront = -Float.infinity
        for foot in feet { foot.forEachRestPosition(budget: 4_000) { footFront = max(footFront, $0.z * forward) } }
        let shoe = try #require(donor.restBounds(ofSlots: AppearancePartKind.shoes.slots))
        let shoeFront = forward > 0 ? shoe.max.z : -shoe.min.z
        #expect(footFront > shoeFront - 0.04, "toes reach \(footFront), shoe front \(shoeFront)")

        host.restoreBaseComposition()
        #expect(host.meshes.count == baseMeshes, "restore takes the foot away with the shoe")
    }
}

private extension VRMPrimitive {
    /// Every vertex the index buffer references (repeats included).
    func forEachVertex(_ body: (VRMVertex) -> Void) {
        guard let vertexBuffer, let indexBuffer else { return }
        let indexBase = indexBuffer.contents().advanced(by: indexBufferOffset)
        for n in 0..<indexCount {
            let index = indexType == .uint32
                ? Int(indexBase.load(fromByteOffset: n * 4, as: UInt32.self))
                : Int(indexBase.load(fromByteOffset: n * 2, as: UInt16.self))
            guard index < vertexCount else { continue }
            body(vertexBuffer.contents().load(
                fromByteOffset: index * MemoryLayout<VRMVertex>.stride, as: VRMVertex.self))
        }
    }
}
