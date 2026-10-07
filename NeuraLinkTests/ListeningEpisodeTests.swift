//
//  ListeningEpisodeTests.swift
//  NeuraLinkTests
//
//  The "listening to music" episode: the policy, the looping body hand-off
//  on the scene state, and how it yields to the phone episode and resumes.
//

import Foundation
import Metal
import Testing

@testable import NeuraLink

@Suite("Listening episode", .serialized)
struct ListeningEpisodeTests {

    @Test("Begin is idempotent, end fires once, the cap reports once")
    func policy() {
        var policy = ListeningEpisodePolicy()
        policy.maxHold = 2
        let endedIdle = policy.end()
        #expect(!endedIdle)
        let began = policy.begin()
        #expect(began)
        let beganAgain = policy.begin()
        #expect(!beganAgain)
        var expiredAt: [Int] = []
        for frame in 1...90 where policy.tick(dt: 1.0 / 30.0) {
            expiredAt.append(frame)
        }
        #expect(expiredAt.count == 1)
        #expect(expiredAt.first.map { abs($0 - 60) <= 1 } == true, "crossed at \(expiredAt)")
        let ended = policy.end()
        #expect(ended)
        let endedAgain = policy.end()
        #expect(!endedAgain)
    }

    @Test("The listening clip ships in the bundle")
    func clipBundled() {
        #expect(Bundle.main.url(forResource: ListeningEpisodePolicy.clipName, withExtension: "vrma") != nil)
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
        state.setupListeningEpisodeObservers()
        // …and the renderer; give it one so the gaze toggle is exercised.
        state.renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        state.display(model)
        for _ in 0..<300 where state.listeningEpisodeClip == nil || state.phoneEpisodeClip == nil || state.defaultClip == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.listeningEpisodeClip != nil, "listen_to_music.vrma preloads with the idle clips")
        tick(state, frames: 900)  // entrance clip done
        #expect(!state.isPlayingAppear)
        return state
    }

    @MainActor
    @Test("The loop owns the body for as long as the episode lasts, then hands back")
    func loopsUntilEnd() async throws {
        guard let state = try await loadedScene() else { return }
        defer { ListeningEpisode.end(reason: "test cleanup") }
        let duration = try #require(state.listeningEpisodeClip?.duration)

        ListeningEpisode.begin(reason: "test")
        tick(state, frames: 1)
        #expect(ListeningEpisode.isActive)
        #expect(state.isPlayingListeningClip)
        #expect(state.animationPlayer.isLooping)
        #expect(state.randomAnimTimer < 0, "idles wait")
        #expect(state.renderer?.lookAtController?.enabled == false, "the clip's head motion shows")

        // Well past three clip lengths: still looping, no gesture, no idle.
        let chat = RealtimeChatState.shared
        let saved = chat.status
        defer { chat.status = saved }
        for _ in 1...6 {
            chat.status = .speaking
            tick(state, frames: Int(duration * 30) / 4)
            chat.status = .ready
            tick(state, frames: Int(duration * 30) / 4)
        }
        #expect(state.isPlayingListeningClip)
        #expect(!state.isPlayingTalkingGesture)
        #expect(!state.isPlayingRandomAnim)

        ListeningEpisode.end(reason: "session stopped")
        #expect(!ListeningEpisode.isActive)
        #expect(!state.isPlayingListeningClip)
        #expect(state.randomAnimTimer >= 0, "idles re-armed")
        #expect(state.renderer?.lookAtController?.enabled == true)
    }

    @MainActor
    @Test("The phone episode borrows the body and the loop resumes after it")
    func yieldsToPhone() async throws {
        guard let state = try await loadedScene() else { return }
        defer {
            PhoneEpisode.end(reason: "test cleanup")
            ListeningEpisode.end(reason: "test cleanup")
        }

        ListeningEpisode.begin(reason: "test")
        tick(state, frames: 1)
        #expect(state.isPlayingListeningClip)

        PhoneEpisode.begin(tool: AppFunctionTool.searchWeb)
        tick(state, frames: 1)
        #expect(state.isPlayingPhoneEpisodeClip)
        #expect(!state.isPlayingListeningClip, "the phone outranks the music")

        PhoneEpisode.end(reason: "spoken result finished")
        tick(state, frames: 2)
        #expect(!state.isPlayingPhoneEpisodeClip)
        #expect(state.isPlayingListeningClip, "the music loop takes the body back")
        #expect(state.listeningEpisode.isActive)
        #expect(state.renderer?.lookAtController?.enabled == false)
    }

    @MainActor
    @Test("A lost stop ends at the safety cap")
    func lostStop() async throws {
        guard let state = try await loadedScene() else { return }
        defer { ListeningEpisode.end(reason: "test cleanup") }
        state.listeningEpisode.maxHold = 1
        ListeningEpisode.begin(reason: "test")
        tick(state, frames: 15)
        #expect(state.isPlayingListeningClip)
        tick(state, frames: 30)
        #expect(!state.listeningEpisode.isActive)
        #expect(!state.isPlayingListeningClip)
        #expect(!ListeningEpisode.isActive, "the app-wide flag follows the cap")
    }
}
