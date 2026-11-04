//
//  AnimationPlayerSwitchTests.swift
//  NeuraLinkTests
//
//  Character switches: a crossfade snapshot holds one model's node poses by
//  index. Landing on the next model, it wrote the first model's bone offsets
//  into the second's skeleton (twisted bones until the character was
//  reloaded). It must stay with the model it was taken from, and the scene's
//  reset must drop it.
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import Testing
import simd
@testable import NeuraLink

@MainActor
@Suite("Animation player across a character switch", .serialized)
struct AnimationPlayerSwitchTests {

    private func load(_ name: String) async throws -> VRMModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "vrm") else { return nil }
        let model = try await VRMModel.load(from: url)
        model.updateNodeTransforms()
        return model
    }

    private func clip(_ name: String, for model: VRMModel) throws -> AnimationClip? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "vrma") else { return nil }
        return try VRMAnimationLoader.loadVRMA(from: url, model: model)
    }

    /// Largest change of any node's local translation from the file's.
    private func translationDrift(_ model: VRMModel) -> Float {
        let hips = model.humanoid?.getBoneNode(.hips)
        return model.nodes.enumerated()
            .filter { $0.offset != hips }
            .map { simd_distance($0.element.translation, $0.element.initialTranslation) }
            .max() ?? 0
    }

    @Test("A crossfade taken on one model never lands on the next")
    func crossfadeStaysWithItsModel() async throws {
        guard let oz = try await load("Oz"), let sonya = try await load("Sonya"),
              let ozIdle = try clip("neutral_4", for: oz), let ozPose = try clip("peace_sign", for: oz),
              let sonyaIdle = try clip("neutral_4", for: sonya)
        else { return }
        let player = AnimationPlayer()
        player.load(ozIdle)
        player.update(deltaTime: 0.5, model: oz)
        player.crossfade(to: ozPose, duration: 1.0, from: oz)

        // The switch, as the scene did it before: the next model's clip
        // loads into the same player while the crossfade is still running.
        player.load(sonyaIdle)
        for _ in 0..<60 { player.update(deltaTime: 1.0 / 60.0, model: sonya) }
        #expect(translationDrift(sonya) < 1e-5, "Oz's bone offsets reached Sonya's skeleton")
    }

    @Test("Reset drops the clip and any crossfade")
    func resetForgetsEverything() async throws {
        guard let oz = try await load("Oz"), let sonya = try await load("Sonya"),
              let ozIdle = try clip("neutral_4", for: oz), let ozPose = try clip("peace_sign", for: oz)
        else { return }
        let player = AnimationPlayer()
        player.load(ozIdle)
        player.update(deltaTime: 0.5, model: oz)
        player.crossfade(to: ozPose, duration: 1.0, from: oz)
        player.reset()

        let before = sonya.nodes.map(\.rotation)
        player.update(deltaTime: 1.0 / 60.0, model: sonya)
        #expect(zip(before, sonya.nodes.map(\.rotation)).allSatisfy { $0 == $1 }, "nothing plays after a reset")
    }
}
