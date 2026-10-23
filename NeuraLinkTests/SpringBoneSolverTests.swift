//
//  SpringBoneSolverTests.swift
//  NeuraLinkTests
//
//  The CPU spring solver on the bundled characters: VRM 1.0 chains are
//  simulated once each (the 0.x root expansion used to duplicate them), and
//  hair that nothing moves comes to a standstill instead of vibrating.
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import Testing
import simd
@testable import NeuraLink

@MainActor
@Suite("Spring bone solver", .serialized)
struct SpringBoneSolverTests {

    private func load(_ name: String) async throws -> VRMModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "vrm") else { return nil }
        return try await VRMModel.load(from: url)
    }

    @Test("A VRM 1.0 model's chains are not expanded: no node is a joint of two chains")
    func vrm1ChainsAreSimulatedOnce() async throws {
        guard let model = try await load("Sonya") else { return }
        #expect(!model.isVRM0)
        let springBone = try #require(model.springBone)
        var seen: [Int: Int] = [:]
        for spring in springBone.springs {
            for joint in spring.joints { seen[joint.node, default: 0] += 1 }
        }
        #expect(seen.values.allSatisfy { $0 == 1 }, "\(seen.filter { $0.value > 1 }.count) nodes in more than one chain")
    }

    @Test("Hair nothing moves comes to a standstill", arguments: ["Oz", "Ekaterina", "Sonya"])
    func restIsStill(name: String) async throws {
        guard let model = try await load(name) else { return }
        let springBone = try #require(model.springBone)
        model.updateNodeTransforms()
        let solver = SpringBoneSolver()
        solver.setUp(model: model)
        #expect(!solver.joints.isEmpty)
        solver.warmUp(steps: 120)

        let tips = springBone.springs.compactMap { spring in spring.joints.last.flatMap { model.nodes[safe: $0.node] } }
        var previous = tips.map(\.worldPosition)
        var largest: Float = 0
        for frame in 0..<120 {
            solver.update(deltaTime: 1.0 / 60.0)
            let current = tips.map(\.worldPosition)
            #expect(current.allSatisfy { !$0.x.isNaN && !$0.y.isNaN && !$0.z.isNaN })
            if frame >= 60 {
                largest = max(largest, zip(current, previous).map { simd_distance($0, $1) }.max() ?? 0)
            }
            previous = current
        }
        #expect(largest < 0.00005, "\(name): a tip still moves \(largest * 1000) mm per frame at rest")
    }
}
