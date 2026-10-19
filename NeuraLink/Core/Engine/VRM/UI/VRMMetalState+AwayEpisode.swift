//
//  VRMMetalState+AwayEpisode.swift
//  NeuraLink
//
//  Body side of the away episode (AwayEpisode.swift) and the desk gaze:
//  the resting clip loops while nobody is at the desk, and while someone
//  is, the look-at follows their face. A pose, the phone and the listening
//  loop outrank the resting clip; it resumes when they hand back.
//
//  Created by Dedicatus on 19/10/2026.
//

import Foundation

extension VRMMetalState {

    private static let awayCrossfade: Float = 0.8

    func setupAwayEpisodeObservers() {
        NotificationCenter.default.addObserver(forName: AwayEpisode.didBegin, object: nil, queue: .main) { [weak self] _ in
            self?.beginAwayEpisode()
        }
        NotificationCenter.default.addObserver(forName: AwayEpisode.didEnd, object: nil, queue: .main) { [weak self] _ in
            self?.endAwayEpisode()
        }
        NotificationCenter.default.addObserver(forName: FacePresenceDetector.didUpdate, object: nil, queue: .main) { [weak self] _ in
            self?.followFace()
        }
    }

    func beginAwayEpisode() {
        guard awayEpisode.begin() else { return }
        startAwayClipIfPossible()
    }

    func endAwayEpisode() {
        guard awayEpisode.end() else { return }
        let wasPlaying = isPlayingAwayClip
        isPlayingAwayClip = false
        guard !phoneEpisode.isActive, !listeningEpisode.isActive, !isPlayingPose else { return }
        renderer?.lookAtController?.enabled = true
        guard wasPlaying, let model = currentModel, let clip = defaultClip else { return }
        animationPlayer.isLooping = true
        animationPlayer.crossfade(to: clip, duration: Self.awayCrossfade, from: model)
        scheduleNextRandomAnim()
        nlLog("[AwayEpisode] ↩ neutral")
    }

    /// Per frame while active: restart the loop whenever the body is free,
    /// and enforce the safety cap.
    func updateAwayEpisode(dt: Float) {
        guard awayEpisode.isActive else { return }
        if awayEpisode.tick(dt: dt) {
            nlLog("[AwayEpisode] expired after \(Int(awayEpisode.maxHold))s without an end", level: .info)
            endAwayEpisode()
            AwayEpisode.end(reason: "safety cap")
            return
        }
        if !isPlayingAwayClip { startAwayClipIfPossible() }
    }

    private func startAwayClipIfPossible() {
        guard let model = currentModel, let clip = awayEpisodeClip,
              !isPlayingAppear, !isPlayingPose, !phoneEpisode.isActive, !listeningEpisode.isActive else { return }
        isPlayingAwayClip = true
        isPlayingRandomAnim = false
        randomAnimElapsed = 0
        randomAnimTimer = -1  // idles wait until the episode hands back
        isPlayingTalkingGesture = false
        renderer?.lookAtController?.enabled = false
        animationPlayer.isLooping = true
        animationPlayer.crossfade(to: clip, duration: Self.awayCrossfade, from: model)
        nlLog("[AwayEpisode] ▶ \(AwayEpisodePolicy.clipName) (loop)")
    }

    // MARK: - Desk gaze

    /// Points the look-at at the user's face while one is in the frame, and
    /// restores whatever it was aimed at when the face is gone. Takes over
    /// from the camera or the forward rest only; a point target set by
    /// something else is left alone.
    private func followFace() {
        guard let lookAt = renderer?.lookAtController else { return }
        let detector = FacePresenceDetector.shared
        if detector.facePresent, let center = detector.faceCenter {
            lookAt.userPosition = FaceGaze.userPosition(center: center, cameraPosition: lookAt.cameraPosition)
            switch lookAt.target {
            case .camera, .forward:
                faceGazeRestoreTarget = lookAt.target
                lookAt.target = .user
            case .user, .point:
                break
            }
        } else if case .user = lookAt.target, let restore = faceGazeRestoreTarget {
            lookAt.target = restore
            faceGazeRestoreTarget = nil
        }
    }
}
