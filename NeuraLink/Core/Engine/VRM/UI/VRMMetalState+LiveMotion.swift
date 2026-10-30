//
//  VRMMetalState+LiveMotion.swift
//  NeuraLink
//
//  A generated motion stream on the body: `beginLiveMotion` crossfades the
//  player onto a LiveMotionSession's clip (hips height included), idles and
//  talking gestures stand down, and the look-at composes on the stream's
//  neck and head. A pose or an episode takes the body back at once; the
//  caller ends the stream when its reply is over and the body crossfades
//  home. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import simd

extension VRMMetalState {

    private static let liveMotionFadeIn: Float = 0.4
    private static let liveMotionFadeOut: Float = 0.5

    /// True while a stream owns the body.
    var isPlayingLiveMotion: Bool { liveMotion != nil }

    /// The coordinator asks for a stream with `.liveMotionRequested`; the
    /// scene answers with a session for the character on screen.
    func setupLiveMotionObserver() {
        NotificationCenter.default.addObserver(forName: .liveMotionRequested, object: nil, queue: .main) { [weak self] note in
            guard let self, let request = note.userInfo?["request"] as? MotionStreamRequest else { return }
            Task { @MainActor in self.startLiveMotionStream(request) }
        }
        MotionStreamCoordinator.shared.refreshAvailability()
        if let caption = MotionStreamCoordinator.shared.debugCaption {
            // After the entrance clip; dropped (and logged) if the body is owned elsewhere.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                nlLog("[LiveMotion] debug caption: \(caption)", level: .info)
                MotionStreamCoordinator.shared.request(MotionStreamRequest(caption: caption, seconds: 8, continuous: false))
            }
        }
    }

    /// Builds the live session for the displayed character and lets the
    /// coordinator fill it; the body crossfades on once the first window is in.
    func startLiveMotionStream(_ request: MotionStreamRequest) {
        guard let model = currentModel, !isPlayingAppear, !isPlayingPose,
              !phoneEpisode.isActive, !listeningEpisode.isActive, !awayEpisode.isActive else {
            nlLog("[LiveMotion] request dropped: the body is owned elsewhere", level: .info)
            return
        }
        let session = LiveMotionSession(model: model)
        MotionStreamCoordinator.shared.begin(
            request, live: session,
            onReady: { [weak self] in self?.beginLiveMotion(session) },
            onFinished: { [weak self] reason in self?.endLiveMotion(reason: reason) })
    }

    /// Starts playing `session` on its model. Ignored while a pose or an
    /// episode has the body, during the entrance, or for another model.
    func beginLiveMotion(_ session: LiveMotionSession) {
        guard let model = currentModel, session.model === model, !isPlayingAppear, !isPlayingPose,
              !phoneEpisode.isActive, !listeningEpisode.isActive, !awayEpisode.isActive else {
            nlLog("[LiveMotion] not started: the body is owned elsewhere", level: .info)
            return
        }
        isPlayingRandomAnim = false
        randomAnimTimer = -1  // idles wait until the stream hands back
        isPlayingTalkingGesture = false
        liveMotion = session
        session.elapsed = 0
        animationPlayer.applyRootMotion = true  // hips height: crouches and bows
        animationPlayer.crossfade(to: session.clip, duration: Self.liveMotionFadeIn, from: model)
        nlLog("[LiveMotion] ▶ stream (\(String(format: "%.1f", session.buffer.duration))s buffered)")
    }

    /// Forgets the stream and the gaze base without touching the player; the
    /// scene's reset calls it as the character leaves.
    func resetLiveMotion() {
        liveMotion = nil
        renderer?.lookAtController?.neckBaseRotation = nil
        renderer?.lookAtController?.headBaseRotation = nil
    }

    /// Ends the stream and hands the body back: to the running episode if
    /// one took over, else to the neutral idle.
    func endLiveMotion(reason: String) {
        guard liveMotion != nil else { return }
        resetLiveMotion()
        MotionStreamCoordinator.shared.cancel()
        animationPlayer.applyRootMotion = false
        guard let model = currentModel, let clip = defaultClip else { return }
        if isPlayingPose || phoneEpisode.isActive || listeningEpisode.isActive || awayEpisode.isActive {
            nlLog("[LiveMotion] ↩ \(reason); the pose or episode resumes")
            return
        }
        animationPlayer.isLooping = true
        animationPlayer.crossfade(to: clip, duration: Self.liveMotionFadeOut, from: model)
        scheduleNextRandomAnim()
        nlLog("[LiveMotion] ↩ neutral (\(reason))")
    }

    /// Per-frame, before the player: give way to whatever outranks the
    /// stream, keep the playhead, drop frames far behind it.
    func updateLiveMotion(dt: Float, model: VRMModel) {
        guard let session = liveMotion else { return }
        if session.model !== model {
            endLiveMotion(reason: "character changed")
            return
        }
        if isPlayingPose || phoneEpisode.isActive || listeningEpisode.isActive || awayEpisode.isActive {
            endLiveMotion(reason: "outranked")
            return
        }
        session.elapsed += dt * animationPlayer.speed
        session.buffer.trim(before: session.elapsed)
        MotionStreamCoordinator.shared.tick(playhead: session.elapsed, speaking: aiState.status == .speaking, deltaTime: dt)
    }

    /// Per-frame, after the player wrote the stream's rotations and before
    /// the look-at runs: the neck and head the gaze should build on.
    func publishLiveMotionHeadBase(model: VRMModel) {
        guard liveMotion != nil, let lookAt = renderer?.lookAtController, let humanoid = model.humanoid else { return }
        model.withLock {
            if let neck = humanoid.getBoneNode(.neck), neck < model.nodes.count {
                lookAt.neckBaseRotation = model.nodes[neck].rotation
            }
            if let head = humanoid.getBoneNode(.head), head < model.nodes.count {
                lookAt.headBaseRotation = model.nodes[head].rotation
            }
        }
    }
}
