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
import Metal
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

    @Test("A steady breeze sways the hair downwind, a little, and still air leaves the spec's step alone")
    func windSwaysHair() async throws {
        guard let model = try await load("Oz") else { return }
        let springBone = try #require(model.springBone)
        model.updateNodeTransforms()
        let solver = SpringBoneSolver()
        #expect(solver.wind == .zero)
        solver.setUp(model: model)
        solver.warmUp(steps: 120)
        let tips = springBone.springs.compactMap { spring in spring.joints.last.flatMap { model.nodes[safe: $0.node] } }
        let still = tips.map(\.worldPosition)

        solver.wind = SIMD3<Float>(SkyWind.strength, 0, 0)
        for _ in 0..<240 { solver.update(deltaTime: 1.0 / 60.0) }
        let blown = tips.map(\.worldPosition)
        let drift = zip(blown, still).map { $0.x - $1.x }
        let mean = drift.reduce(0, +) / Float(max(drift.count, 1))
        #expect(blown.allSatisfy { !$0.x.isNaN && !$0.y.isNaN && !$0.z.isNaN })
        #expect(mean > 0.001, "tips moved \(mean * 1000) mm downwind")
        #expect((drift.max() ?? 0) < 0.15, "a tip blew \((drift.max() ?? 0) * 100) cm: more than a breeze")
    }

    @Test("The breeze blows the clouds' way, in gusts that never stop, harder in the rain")
    func breeze() {
        var calmest = Float.infinity, strongest: Float = 0
        for second in stride(from: Float(0), to: 600, by: 0.5) {
            let air = SkyWind.velocity(time: second, cloudSpeed: 0.026, rain: 0)
            #expect(air.y == 0)
            calmest = min(calmest, simd_length(air))
            strongest = max(strongest, simd_length(air))
            // Within the wandering of the clouds' downwind bearing.
            let off = abs(remainder(atan2(air.z, air.x) - SkyWind.downwind, 2 * .pi))
            #expect(off < 0.7)
        }
        #expect(calmest > 0.05 && strongest < SkyWind.strength * 1.3)
        let dry = simd_length(SkyWind.velocity(time: 30, cloudSpeed: 0.02, rain: 0))
        let wet = simd_length(SkyWind.velocity(time: 30, cloudSpeed: 0.02, rain: 1))
        #expect(wet > dry * 1.5)
    }

    @Test("The breeze reaches the springs in the model's own space: turned back for a VRM 0.x model",
          arguments: ["Oz", "Ekaterina", "Sonya"])
    func windInModelSpace(name: String) async throws {
        guard UserSettings.shared.wind, let device = MTLCreateSystemDefaultDevice(),
              let url = Bundle.main.url(forResource: name, withExtension: "vrm") else { return }
        let model = try await VRMModel.load(from: url, device: device)
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: 1))
        renderer.loadModel(model)
        renderer.modelIsImported = false
        let sky = try #require(renderer.skyRenderer)
        let scene = SkyWind.velocity(
            time: sky.cloudTime, cloudSpeed: sky.currentEnvironment.cloudSpeed, rain: sky.rainIntensity)
        // The scene draws a 0.x model turned 180° about Y.
        let expected = model.isVRM0 ? SIMD3<Float>(-scene.x, scene.y, -scene.z) : scene
        #expect(simd_distance(renderer.springBoneWind(), expected) < 1e-5, "\(name)")
        renderer.clearModel()
    }
}
