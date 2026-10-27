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

    @Test("VRM 1.0 joint settings and collider shapes are read as the file has them")
    @MainActor
    func vrm1ValuesAreExact() async throws {
        // `as? Float` is nil for a JSON decimal a Float can't hold exactly
        // (0.85): every such joint and collider used to fall back to defaults.
        guard let url = Bundle.main.url(forResource: "Sonya", withExtension: "vrm") else { return }
        let model = try await VRMModel.load(from: url, device: nil)
        let springBone = try #require(model.springBone)
        let root = try Self.rawJSON(of: url)
        let raw = try #require((root["extensions"] as? [String: Any])?["VRMC_springBone"] as? [String: Any])
        func float(_ value: Any?) -> Float? { (value as? NSNumber)?.floatValue }

        var checkedJoints = 0, inexact = 0
        for (spring, rawSpring) in zip(springBone.springs, raw["springs"] as? [[String: Any]] ?? []) {
            for (joint, rawJoint) in zip(spring.joints, rawSpring["joints"] as? [[String: Any]] ?? []) {
                if let value = float(rawJoint["stiffness"]) {
                    #expect(abs(joint.stiffness - value) < 1e-6)
                }
                for key in ["stiffness", "dragForce", "hitRadius"] {
                    if let double = (rawJoint[key] as? NSNumber)?.doubleValue, Double(Float(double)) != double { inexact += 1 }
                }
                if let value = float(rawJoint["dragForce"]) { #expect(abs(joint.dragForce - value) < 1e-6) }
                if let value = float(rawJoint["hitRadius"]) { #expect(abs(joint.hitRadius - value) < 1e-6) }
                checkedJoints += 1
            }
        }
        #expect(checkedJoints > 0)
        #expect(inexact > 0, "the fixture must have settings a Float can't hold exactly")

        for (collider, rawCollider) in zip(springBone.colliders, raw["colliders"] as? [[String: Any]] ?? []) {
            let shape = rawCollider["shape"] as? [String: Any] ?? [:]
            let rawShape = (shape["sphere"] ?? shape["capsule"]) as? [String: Any] ?? [:]
            let rawOffset = (rawShape["offset"] as? [Any] ?? []).compactMap(float)
            switch collider.shape {
            case .sphere(let offset, let radius), .insideSphere(let offset, let radius):
                #expect(rawOffset.count == 3 && simd_distance(offset, SIMD3(rawOffset[0], rawOffset[1], rawOffset[2])) < 1e-6)
                #expect(abs(radius - (float(rawShape["radius"]) ?? -1)) < 1e-6)
            case .capsule(let offset, _, let tail), .insideCapsule(let offset, _, let tail):
                let rawTail = (rawShape["tail"] as? [Any] ?? []).compactMap(float)
                #expect(rawOffset.count == 3 && simd_distance(offset, SIMD3(rawOffset[0], rawOffset[1], rawOffset[2])) < 1e-6)
                #expect(rawTail.count == 3 && simd_distance(tail, SIMD3(rawTail[0], rawTail[1], rawTail[2])) < 1e-6)
            case .plane: break
            }
        }
    }

    @Test("Extended colliders: inside sphere and capsule, and plane, replace the fallback shape")
    func extendedColliders() throws {
        let json = """
        {"specVersion": "1.0", "colliders": [
          {"node": 0, "shape": {"sphere": {"offset": [0, -10000, 0], "radius": 0}},
           "extensions": {"VRMC_springBone_extended_collider": {"specVersion": "1.0",
             "shape": {"sphere": {"offset": [0, 0.1, 0], "radius": 0.3, "inside": true}}}}},
          {"node": 0, "shape": {"sphere": {"offset": [0, -10000, 0], "radius": 0}},
           "extensions": {"VRMC_springBone_extended_collider": {"specVersion": "1.0",
             "shape": {"capsule": {"offset": [0, 0, 0], "tail": [0, 0.2, 0], "radius": 0.05, "inside": true}}}}},
          {"node": 0, "shape": {"sphere": {"offset": [0, -1000, 0], "radius": 1000}},
           "extensions": {"VRMC_springBone_extended_collider": {"specVersion": "1.0",
             "shape": {"plane": {"offset": [0, 0.01, 0], "normal": [0, 1, 0]}}}}},
          {"node": 0, "shape": {"sphere": {"offset": [0, 0.05, 0], "radius": 0.07}}}
        ]}
        """
        let dict = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let shapes = try VRMExtensionParser().parseSpringBone(dict).colliders.map(\.shape)
        #expect(shapes.count == 4)
        guard shapes.count == 4 else { return }
        if case .insideSphere(let offset, let radius) = shapes[0] {
            #expect(simd_distance(offset, [0, 0.1, 0]) < 1e-6 && abs(radius - 0.3) < 1e-6)
        } else { Issue.record("expected an inside sphere: \(shapes[0])") }
        if case .insideCapsule(_, let radius, let tail) = shapes[1] {
            #expect(abs(radius - 0.05) < 1e-6 && simd_distance(tail, [0, 0.2, 0]) < 1e-6)
        } else { Issue.record("expected an inside capsule: \(shapes[1])") }
        if case .plane(let offset, let normal) = shapes[2] {
            #expect(simd_distance(offset, [0, 0.01, 0]) < 1e-6 && simd_distance(normal, [0, 1, 0]) < 1e-6)
        } else { Issue.record("expected a plane: \(shapes[2])") }
        if case .sphere(let offset, _) = shapes[3] {
            #expect(simd_distance(offset, [0, 0.05, 0]) < 1e-6, "0.05 survives the parse")
        } else { Issue.record("expected a plain sphere: \(shapes[3])") }
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
