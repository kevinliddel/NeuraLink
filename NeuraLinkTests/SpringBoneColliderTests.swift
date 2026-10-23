//
//  SpringBoneColliderTests.swift
//  NeuraLinkTests
//
//  Two spring-bone rules the reference importers follow and the engine once
//  did not: a VRM 0.x collider offset has its Z flipped into glTF space, and
//  a chain that names no collider groups collides with nothing. Both bugs
//  showed up as hair and outfits that twitched with the character standing
//  still (misplaced head colliders pushing tips about, skirt chains hitting
//  the chest). Pinned against the bundled Ekaterina, a VRM 0.x VRoid export.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Metal
import Testing
import simd
@testable import NeuraLink

@Suite("Spring bone colliders")
struct SpringBoneColliderTests {

    /// The raw VRM 0.x JSON chunk of a .vrm file.
    private static func rawJSON(of url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let chunkLength = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let json = data.subdata(in: 20..<(20 + Int(chunkLength)))
        return try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    @Test("A VRM 0.x collider offset is read with Z flipped and X, Y intact")
    @MainActor
    func vrm0ColliderOffsetFlipsZ() async throws {
        guard let url = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm") else { return }
        let model = try await VRMModel.load(from: url, device: nil)
        let springBone = try #require(model.springBone)
        let root = try Self.rawJSON(of: url)
        let secondary = try #require(((root["extensions"] as? [String: Any])?["VRM"] as? [String: Any])?["secondaryAnimation"] as? [String: Any])
        let groups = try #require(secondary["colliderGroups"] as? [[String: Any]])

        var checked = 0
        var sawNonZeroZ = false
        var parsedIndex = 0
        for group in groups {
            for raw in group["colliders"] as? [[String: Any]] ?? [] {
                let offset = raw["offset"] as? [String: Any] ?? [:]
                let rawX = (offset["x"] as? NSNumber)?.floatValue ?? 0
                let rawY = (offset["y"] as? NSNumber)?.floatValue ?? 0
                let rawZ = (offset["z"] as? NSNumber)?.floatValue ?? 0
                guard case .sphere(let parsed, _) = springBone.colliders[parsedIndex].shape else {
                    Issue.record("collider \(parsedIndex) is not a sphere")
                    return
                }
                #expect(abs(parsed.x - rawX) < 1e-6)
                #expect(abs(parsed.y - rawY) < 1e-6)
                #expect(abs(parsed.z + rawZ) < 1e-6, "collider \(parsedIndex): z \(parsed.z) vs raw \(rawZ)")
                if abs(rawZ) > 1e-4 { sawNonZeroZ = true }
                parsedIndex += 1
                checked += 1
            }
        }
        #expect(checked == springBone.colliders.count)
        #expect(sawNonZeroZ, "the fixture must have a collider with a forward offset for the flip to be observable")
    }

    @Test("A chain with no collider groups collides with nothing; the others get exactly their groups")
    @MainActor
    func emptyColliderGroupsMeanNoCollision() async throws {
        guard let url = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm") else { return }
        let model = try await VRMModel.load(from: url, device: MTLCreateSystemDefaultDevice())
        let springBone = try #require(model.springBone)
        let solver = SpringBoneSolver()
        solver.setUp(model: model)
        let chains = solver.chainColliders
        #expect(chains.count == springBone.springs.count)

        var emptyChains = 0
        for (spring, colliders) in zip(springBone.springs, chains) {
            let expected = Set(spring.colliderGroups.flatMap { springBone.colliderGroups[$0].colliders })
            if spring.colliderGroups.isEmpty { emptyChains += 1 }
            #expect(Set(colliders) == expected)
        }
        #expect(emptyChains > 0, "the fixture must have chains that name no collider groups")
    }
}
