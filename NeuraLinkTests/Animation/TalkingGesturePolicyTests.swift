//
//  TalkingGesturePolicyTests.swift
//  NeuraLinkTests
//
//  The occasional talking gesture: cooldown, guarantee and long-run rate
//  (about one reply in three).
//

import Foundation
import Metal
import Testing

@testable import NeuraLink

@Suite("Talking gesture policy")
struct TalkingGesturePolicyTests {

    @Test("No gesture during the cooldown, even on a winning roll")
    func cooldown() {
        var policy = TalkingGesturePolicy()
        for _ in 0..<policy.cooldown {
            let fired = policy.shouldGesture(roll: 0)
            #expect(!fired)
        }
        let afterCooldown = policy.shouldGesture(roll: 0)
        #expect(afterCooldown)
        // Right after a gesture the cooldown applies again.
        let next = policy.shouldGesture(roll: 0)
        #expect(!next)
    }

    @Test("The guaranteeAfter-th reply always gestures")
    func guarantee() {
        var policy = TalkingGesturePolicy()
        var fired: [Bool] = []
        for _ in 0..<policy.guaranteeAfter {
            fired.append(policy.shouldGesture(roll: 0.99))
        }
        #expect(fired.dropLast().allSatisfy { !$0 })
        #expect(fired.last == true)
        #expect(policy.repliesSinceGesture == 0)
    }

    @Test("Long-run rate is three to four gestures per ten replies")
    func rate() {
        var policy = TalkingGesturePolicy()
        var generator = SplitMix64(seed: 42)
        let replies = 10_000
        var gestures = 0
        for _ in 0..<replies where policy.shouldGesture(roll: Double.random(in: 0..<1, using: &generator)) {
            gestures += 1
        }
        let perTen = Double(gestures) / Double(replies) * 10
        #expect((3.0...4.0).contains(perTen), "got \(perTen) per 10 replies")
    }

    @Test("Gesture clips ship in the bundle")
    func clipsBundled() {
        for name in TalkingGesturePolicy.clipNames {
            #expect(Bundle.main.url(forResource: name, withExtension: "vrma") != nil, "\(name).vrma missing")
        }
    }
}

/// Deterministic generator so the rate test never flakes.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// End to end on a real VRMMetalState: load Sonya, let the clips load and
/// the entrance finish, then simulate spoken replies frame by frame.
@MainActor
@Suite("Talking gesture playback", .serialized)
struct TalkingGesturePlaybackTests {

    private func tick(_ state: VRMMetalState, frames: Int) {
        for _ in 0..<frames { state.animationTickInternal(dt: 1.0 / 30.0) }
    }

    @Test("A gesture plays within four spoken replies")
    func gesturePlays() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let url = try #require(Bundle.main.url(forResource: "Sonya", withExtension: "vrm"))
        let model = try await VRMModel.load(from: url, device: device)
        let state = VRMMetalState()
        state.display(model)
        for _ in 0..<300 where state.talkingGestureEntries.isEmpty || state.defaultClip == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.talkingGestureEntries.map(\.name).sorted() == ["speaking", "talking"])

        tick(state, frames: 900)  // entrance clip done
        #expect(!state.isPlayingAppear)

        let chat = RealtimeChatState.shared
        let saved = chat.status
        defer { chat.status = saved }
        var startedOnReply: Int?
        for reply in 1...4 where startedOnReply == nil {
            chat.status = .speaking
            tick(state, frames: 1)
            if state.isPlayingTalkingGesture { startedOnReply = reply }
            tick(state, frames: 150)
            chat.status = .ready
            tick(state, frames: 30)
        }
        #expect(startedOnReply != nil, "no gesture in 4 replies (pose=\(state.isPlayingPose))")

        // …and it hands back to the idle afterwards.
        tick(state, frames: 200)
        #expect(!state.isPlayingTalkingGesture)
    }

    @Test("A pose that never stops expires and frees gestures")
    func poseExpires() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let url = try #require(Bundle.main.url(forResource: "Sonya", withExtension: "vrm"))
        let model = try await VRMModel.load(from: url, device: device)
        let state = VRMMetalState()
        state.display(model)
        for _ in 0..<300 where state.defaultClip == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        tick(state, frames: 900)
        state.isPlayingPose = true
        state.poseStartedAt = Date().addingTimeInterval(-(VRMMetalState.poseMaxHold + 1))
        tick(state, frames: 1)
        #expect(!state.isPlayingPose)
    }
}
