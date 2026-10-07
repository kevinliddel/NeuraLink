//
//  VRMMetalState+ListeningEpisode.swift
//  NeuraLink
//
//  Body side of the listening episode (ListeningEpisode.swift): the
//  listen_to_music clip loops with gaze tracking off, so the clip's head
//  motion shows, for as long as the episode lasts. A pose or the phone
//  episode outranks it and the loop resumes when they hand the body back.
//
//  Created by Dedicatus on 07/10/2026.
//

import Foundation

extension VRMMetalState {

    private static let listeningCrossfade: Float = 0.6

    func setupListeningEpisodeObservers() {
        NotificationCenter.default.addObserver(forName: ListeningEpisode.didBegin, object: nil, queue: .main) { [weak self] _ in
            self?.beginListeningEpisode()
        }
        NotificationCenter.default.addObserver(forName: ListeningEpisode.didEnd, object: nil, queue: .main) { [weak self] _ in
            self?.endListeningEpisode()
        }
    }

    func beginListeningEpisode() {
        guard listeningEpisode.begin() else { return }
        startListeningClipIfPossible()
    }

    /// Hands the body back: gaze on, crossfade to neutral, idles re-armed —
    /// unless the phone episode or a pose holds it, which hand back on
    /// their own.
    func endListeningEpisode() {
        guard listeningEpisode.end() else { return }
        let wasPlaying = isPlayingListeningClip
        isPlayingListeningClip = false
        guard !phoneEpisode.isActive, !isPlayingPose else { return }
        renderer?.lookAtController?.enabled = true
        guard wasPlaying, let model = currentModel, let clip = defaultClip else { return }
        animationPlayer.isLooping = true
        animationPlayer.crossfade(to: clip, duration: Self.listeningCrossfade, from: model)
        scheduleNextRandomAnim()
        nlLog("[ListeningEpisode] ↩ neutral")
    }

    /// Per frame while active: (re)start the loop whenever the body is free,
    /// and enforce the safety cap.
    func updateListeningEpisode(dt: Float) {
        guard listeningEpisode.isActive else { return }
        if listeningEpisode.tick(dt: dt) {
            nlLog("[ListeningEpisode] expired after \(Int(listeningEpisode.maxHold))s without a stop", level: .info)
            endListeningEpisode()
            ListeningEpisode.end(reason: "safety cap")
            return
        }
        if !isPlayingListeningClip { startListeningClipIfPossible() }
    }

    private func startListeningClipIfPossible() {
        guard let model = currentModel, let clip = listeningEpisodeClip,
              !isPlayingAppear, !isPlayingPose, !phoneEpisode.isActive else { return }
        isPlayingListeningClip = true
        isPlayingRandomAnim = false
        randomAnimElapsed = 0
        randomAnimTimer = -1  // idles wait until the episode hands back
        isPlayingTalkingGesture = false
        renderer?.lookAtController?.enabled = false
        animationPlayer.isLooping = true
        animationPlayer.crossfade(to: clip, duration: Self.listeningCrossfade, from: model)
        nlLog("[ListeningEpisode] ▶ \(ListeningEpisodePolicy.clipName) (loop)")
    }
}
