//
//  ListeningEpisode.swift
//  NeuraLink
//
//  The companion "listening to music": while song recognition records a
//  snippet, and for the whole of a listening-together session, the body
//  loops listen_to_music.vrma. Idles, talking gestures and look-back wait;
//  a photoshoot pose or the phone episode may borrow the body and the loop
//  resumes when they hand it back.
//
//  Begins in SongRecognitionManager when a capture starts (one-shot) or the
//  session starts; ends when the one-shot finishes, the session stops (user,
//  30-minute cap, background, route change, battery, failures), the scene
//  is cleared, or at the safety cap.
//
//  Created by Dedicatus on 07/10/2026.
//

import Foundation

/// How long the loop may run without a stop. Framework-free and
/// unit-tested; the scene state owns one and advances it per frame.
nonisolated struct ListeningEpisodePolicy: Equatable {
    static let clipName = "listen_to_music"

    /// A co-listening session caps itself at 30 minutes; this is only the
    /// net under a lost stop.
    var maxHold: Float = 31 * 60
    private(set) var isActive = false
    private(set) var elapsed: Float = 0

    /// True on idle → active; a second begin joins the running episode.
    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        elapsed = 0
        return true
    }

    /// True only when an episode was active.
    mutating func end() -> Bool {
        guard isActive else { return false }
        isActive = false
        elapsed = 0
        return true
    }

    /// Advances the hold. True on the one frame the cap is crossed.
    mutating func tick(dt: Float) -> Bool {
        guard isActive else { return false }
        let before = elapsed
        elapsed += dt
        return before < maxHold && elapsed >= maxHold
    }
}

/// App-wide switch the song-recognition manager flips; the scene state
/// observes it.
@MainActor
enum ListeningEpisode {
    static let didBegin = Notification.Name("NeuraLink.ListeningEpisode.didBegin")
    static let didEnd = Notification.Name("NeuraLink.ListeningEpisode.didEnd")

    private(set) static var isActive = false

    /// Always re-posts, even mid-episode: a scene that lost the episode (a
    /// character switch, the safety cap) picks the next begin back up.
    static func begin(reason: String) {
        isActive = true
        NotificationCenter.default.post(name: didBegin, object: nil)
        nlLog("[ListeningEpisode] ▶ begin (\(reason))", level: .info)
    }

    static func end(reason: String) {
        guard isActive else { return }
        isActive = false
        NotificationCenter.default.post(name: didEnd, object: nil)
        nlLog("[ListeningEpisode] ■ end (\(reason))", level: .info)
    }
}
