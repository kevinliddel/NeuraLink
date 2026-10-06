//
//  PhoneEpisodeTests.swift
//  NeuraLinkTests
//
//  The "checking my phone" episode: which tools start it, idempotent
//  begin/end, the safety cap, and the body hand-off on the scene state.
//

import Foundation
import Metal
import Testing

@testable import NeuraLink

@Suite("Phone episode", .serialized)
struct PhoneEpisodeTests {

    @Test("Only phone-worthy tools start an episode")
    func allowlist() {
        let phoneTools = [
            AppFunctionTool.searchWeb, AppFunctionTool.playMusic, AppFunctionTool.openApp,
            AppFunctionTool.createNote, AppFunctionTool.getWeather, AppFunctionTool.createReminder
        ]
        for tool in phoneTools {
            #expect(PhoneEpisodePolicy.involvesPhone(tool), "\(tool) should start an episode")
        }
        let others = [
            AppFunctionTool.setEmotion, AppFunctionTool.analyzeCamera, AppFunctionTool.poseForPhoto,
            AppFunctionTool.identifySong, AppFunctionTool.rememberFact, AppFunctionTool.searchMemory,
            AppFunctionTool.showPhoto, AppFunctionTool.playGame
        ]
        for tool in others {
            #expect(!PhoneEpisodePolicy.involvesPhone(tool), "\(tool) must not start an episode")
        }
    }

    @Test("Begin is idempotent, end fires once")
    func beginEnd() {
        var policy = PhoneEpisodePolicy()
        // `#expect` captures its sub-expressions, so mutating calls go in locals.
        let endedIdle = policy.end()
        #expect(!endedIdle)
        let began = policy.begin()
        #expect(began)
        #expect(policy.isActive)
        let beganAgain = policy.begin()
        #expect(!beganAgain)  // a chained tool call joins the episode
        let ended = policy.end()
        #expect(ended)
        #expect(!policy.isActive)
        let endedAgain = policy.end()
        #expect(!endedAgain)
    }

    @Test("The safety cap reports once, at the cap")
    func safetyCap() {
        var policy = PhoneEpisodePolicy()
        policy.maxHold = 2
        let idleTick = policy.tick(dt: 1)
        #expect(!idleTick)  // idle: nothing to cap
        _ = policy.begin()
        var expiredAt: [Int] = []
        for frame in 1...90 where policy.tick(dt: 1.0 / 30.0) {
            expiredAt.append(frame)
        }
        #expect(expiredAt.count == 1)
        #expect(expiredAt.first.map { abs($0 - 60) <= 1 } == true, "crossed at \(expiredAt)")
        _ = policy.end()
        _ = policy.begin()
        #expect(policy.elapsed == 0)  // a new episode starts the clock again
    }

    @Test("The phone clip ships in the bundle")
    func clipBundled() {
        #expect(Bundle.main.url(forResource: PhoneEpisodePolicy.clipName, withExtension: "vrma") != nil)
    }

    // MARK: - Scene state

    @MainActor
    private func tick(_ state: VRMMetalState, frames: Int) {
        for _ in 0..<frames { state.animationTickInternal(dt: 1.0 / 30.0) }
    }

    @MainActor
    private func loadedScene() async throws -> VRMMetalState? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let url = try #require(Bundle.main.url(forResource: "Sonya", withExtension: "vrm"))
        let model = try await VRMModel.load(from: url, device: device)
        let state = VRMMetalState()
        state.setupPhoneEpisodeObservers()  // init skips observers under XCTest…
        // …and the renderer; give it one so the gaze toggle is exercised.
        state.renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        state.display(model)
        for _ in 0..<300 where state.phoneEpisodeClip == nil || state.defaultClip == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.phoneEpisodeClip != nil, "checking_phone.vrma preloads with the idle clips")
        tick(state, frames: 900)  // entrance clip done
        #expect(!state.isPlayingAppear)
        return state
    }

    @MainActor
    @Test("The episode owns the body, keeps gestures out, and hands back on end")
    func bodyHandOff() async throws {
        guard let state = try await loadedScene() else { return }
        defer { PhoneEpisode.end(reason: "test cleanup") }

        #expect(state.renderer?.lookAtController?.enabled == true, "gaze on before the episode")
        PhoneEpisode.begin(tool: AppFunctionTool.searchWeb)
        tick(state, frames: 1)
        #expect(PhoneEpisode.isActive)
        #expect(state.phoneEpisode.isActive)
        #expect(state.isPlayingPhoneEpisodeClip)
        #expect(state.randomAnimTimer < 0, "idles wait during the episode")
        #expect(state.renderer?.lookAtController?.enabled == false, "gaze off: the clip owns the head")

        // Spoken replies during the episode never start a talking gesture
        // (the policy alone would guarantee one within four replies).
        let chat = RealtimeChatState.shared
        let saved = chat.status
        defer { chat.status = saved }
        for _ in 1...6 {
            chat.status = .speaking
            tick(state, frames: 2)
            chat.status = .ready
            tick(state, frames: 2)
        }
        #expect(!state.isPlayingTalkingGesture)

        PhoneEpisode.end(reason: "spoken result finished")
        #expect(!PhoneEpisode.isActive)
        #expect(!state.phoneEpisode.isActive)
        #expect(!state.isPlayingPhoneEpisodeClip)
        #expect(state.randomAnimTimer >= 0, "idles re-armed after the episode")
        #expect(state.renderer?.lookAtController?.enabled == true, "gaze back on")
        // A second end is a no-op.
        PhoneEpisode.end(reason: "again")
        #expect(!state.phoneEpisode.isActive)
    }

    @MainActor
    @Test("A lost stop ends at the safety cap")
    func lostStop() async throws {
        guard let state = try await loadedScene() else { return }
        defer { PhoneEpisode.end(reason: "test cleanup") }

        state.phoneEpisode.maxHold = 1
        PhoneEpisode.begin(tool: AppFunctionTool.createReminder)
        tick(state, frames: 15)  // 0.5 s in: still holding
        #expect(state.isPlayingPhoneEpisodeClip)
        tick(state, frames: 30)  // past 1 s: cap fired
        #expect(!state.phoneEpisode.isActive)
        #expect(!state.isPlayingPhoneEpisodeClip)
        #expect(!PhoneEpisode.isActive, "the app-wide flag follows the cap")
        #expect(state.randomAnimTimer >= 0)
        #expect(state.renderer?.lookAtController?.enabled == true, "gaze back on after the cap")
    }

    // MARK: - App-wide switch

    @MainActor
    @Test("The executor opens the episode for phone tools only and marks the tool finished")
    func executorWiring() async {
        PhoneEpisode.end(reason: "test start")
        defer { PhoneEpisode.end(reason: "test cleanup") }
        let executor = AppFunctionExecutor.shared
        let before = PhoneEpisode.generation

        _ = await executor.execute(name: "no_such_tool", arguments: [:])
        #expect(!PhoneEpisode.isActive)

        _ = await executor.execute(name: AppFunctionTool.searchWeb, arguments: ["query": "phone episode test"])
        #expect(PhoneEpisode.isActive)
        #expect(!PhoneEpisode.isRunningTool, "the skill returned; the result is about to be spoken")
        #expect(PhoneEpisode.generation == before + 1)
        executor.pendingUIAction = nil  // the queued widget is not under test here
    }

    @MainActor
    @Test("A stale after-speech timer cannot end a newer episode")
    func staleEndIgnored() {
        PhoneEpisode.end(reason: "test start")
        defer { PhoneEpisode.end(reason: "test cleanup") }
        PhoneEpisode.begin(tool: AppFunctionTool.searchWeb)
        let first = PhoneEpisode.generation
        PhoneEpisode.begin(tool: AppFunctionTool.playMusic)  // a chained call joins the episode
        #expect(PhoneEpisode.generation == first + 1)
        PhoneEpisode.end(reason: "timer from the first call", generation: first)
        #expect(PhoneEpisode.isActive, "the first call's timer must leave the joined episode alone")
        PhoneEpisode.end(reason: "timer from the second call", generation: first + 1)
        #expect(!PhoneEpisode.isActive)
    }
}
