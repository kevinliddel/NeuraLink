//
//  MotionStreamCoordinatorTests.swift
//  NeuraLinkTests
//
//  The coordinator's loop with a stub producer instead of the model: the
//  scene is told when the first window is in, windows keep coming while the
//  lead is short and the character speaks, a replan reaches the producer,
//  and the stream ends once it has played out or is cancelled.
//  docs/REALTIME_MOTION_PLAN.md, Phase 4.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Metal
import Testing

@testable import NeuraLink

/// Appends `windowSeconds` of T-pose frames per window and counts calls.
private actor StubProducer: MotionWindowProducer {
    private(set) var captions: [String] = []
    private(set) var windows = 0
    let windowSeconds: Float = 2

    func start(caption: String) async throws { captions.append(caption) }
    func replan(caption: String) async throws { captions.append(caption) }

    func nextWindow(into live: LiveMotionSession, steps: Int) async throws -> Float {
        windows += 1
        let frames = Int(windowSeconds * live.buffer.framesPerSecond)
        var rotations = [Float](repeating: 0, count: frames * 27 * 9)
        for frame in 0..<frames {
            for joint in 0..<27 {
                let base = (frame * 27 + joint) * 9
                rotations[base] = 1
                rotations[base + 4] = 1
                rotations[base + 8] = 1
            }
        }
        var roots = [Float](repeating: 0, count: frames * 3)
        for frame in 0..<frames { roots[frame * 3 + 1] = 0.966 }
        live.append(frames: frames, globalRotations: rotations, rootPositions: roots)
        return windowSeconds
    }
}

@MainActor
@Suite("Motion stream coordinator", .serialized)
struct MotionStreamCoordinatorTests {

    private static func model() async throws -> VRMModel? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let url = try #require(Bundle.main.url(forResource: "Sonya", withExtension: "vrm"))
        return try await VRMModel.load(from: url, device: device)
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(350))
    }

    @Test("Fills the lead, reports ready, ends when played out")
    func lifecycle() async throws {
        guard let model = try await Self.model() else { return }
        let coordinator = MotionStreamCoordinator()
        let live = LiveMotionSession(model: model)
        let producer = StubProducer()
        var ready = 0
        var finished: [String] = []
        coordinator.begin(
            MotionStreamRequest(caption: "A person waves with the right hand.", seconds: 4, continuous: false), live: live, producer: producer,
            onReady: { ready += 1 }, onFinished: { finished.append($0) })
        await Self.settle()
        #expect(ready == 1)
        #expect(coordinator.isStreaming)
        // Budget 4 s, lead 2.5 s: both windows come at once since the playhead is at 0.
        #expect(await producer.windows == 2)
        #expect(await producer.captions == ["A person waves with the right hand."])
        #expect(live.buffer.frameCount == 80)

        // The playhead runs to the end while speaking; nothing more is generated.
        coordinator.tick(playhead: 3.9, speaking: true, deltaTime: 0.1)
        await Self.settle()
        #expect(await producer.windows == 2)
        #expect(finished.isEmpty)
        coordinator.tick(playhead: 4.0, speaking: true, deltaTime: 0.1)
        #expect(finished == ["played out"])
        #expect(!coordinator.isStreaming)
    }

    @Test("A replan reaches the producer and extends the budget")
    func replan() async throws {
        guard let model = try await Self.model() else { return }
        let coordinator = MotionStreamCoordinator()
        let live = LiveMotionSession(model: model)
        let producer = StubProducer()
        coordinator.begin(
            MotionStreamRequest(caption: "A person nods the head up and down several times.", seconds: 2, continuous: false),
            live: live, producer: producer, onReady: {}, onFinished: { _ in })
        await Self.settle()
        #expect(await producer.windows == 1)
        #expect(coordinator.request(MotionStreamRequest(caption: "A person shrugs.", seconds: 2, continuous: false)) == false,
                "request() needs the real availability; replan goes through begin's path in the app")
        coordinator.tick(playhead: 1.0, speaking: true, deltaTime: 0.1)
        coordinator.cancel()
        #expect(!coordinator.isStreaming)
        await Self.settle()
        #expect(await producer.captions.count == 1)
    }

    @Test("Silence past the tail stops generation and the stream ends when played")
    func silence() async throws {
        guard let model = try await Self.model() else { return }
        let coordinator = MotionStreamCoordinator()
        let live = LiveMotionSession(model: model)
        let producer = StubProducer()
        var finished: [String] = []
        coordinator.begin(
            MotionStreamRequest(caption: "A person talks, gesturing with both hands.", seconds: nil, continuous: true),
            live: live, producer: producer, onReady: {}, onFinished: { finished.append($0) })
        await Self.settle()
        let afterStart = await producer.windows
        #expect(afterStart == 2)
        for _ in 0..<20 { coordinator.tick(playhead: 1.0, speaking: false, deltaTime: 0.1) }
        await Self.settle()
        #expect(await producer.windows == afterStart, "no window after the tail")
        coordinator.tick(playhead: 4.0, speaking: false, deltaTime: 0.1)
        #expect(finished == ["played out"])
    }
}
