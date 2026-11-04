//
//  AwayEpisode.swift
//  NeuraLink
//
//  The companion "away": nobody has been at the desk for a while, so the
//  body loops a resting clip until a face is back (docs/LIVING_COMPANION.md,
//  Desk presence). Lowest-priority episode: idles stop, but a pose, the
//  phone and the listening loop all outrank it and it resumes after them.
//
//  Created by Dedicatus on 19/10/2026.
//

import Foundation

/// Framework-free and unit-tested; the scene state owns one.
nonisolated struct AwayEpisodePolicy: Equatable {
    /// No dedicated "reading" clip ships yet; `relax` is the resting loop.
    static let clipName = "relax"

    /// A net under a lost end: nobody rests for four hours.
    var maxHold: Float = 4 * 60 * 60
    private(set) var isActive = false
    private(set) var elapsed: Float = 0

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        elapsed = 0
        return true
    }

    mutating func end() -> Bool {
        guard isActive else { return false }
        isActive = false
        elapsed = 0
        return true
    }

    /// True on the one frame the cap is crossed.
    mutating func tick(dt: Float) -> Bool {
        guard isActive else { return false }
        let before = elapsed
        elapsed += dt
        return before < maxHold && elapsed >= maxHold
    }
}

/// App-wide switch the desk-presence manager flips; the scene observes it.
@MainActor
enum AwayEpisode {
    static let didBegin = Notification.Name("NeuraLink.AwayEpisode.didBegin")
    static let didEnd = Notification.Name("NeuraLink.AwayEpisode.didEnd")

    private(set) static var isActive = false

    static func begin(reason: String) {
        isActive = true
        NotificationCenter.default.post(name: didBegin, object: nil)
        nlLog("[AwayEpisode] ▶ begin (\(reason))", level: .info)
    }

    static func end(reason: String) {
        guard isActive else { return }
        isActive = false
        NotificationCenter.default.post(name: didEnd, object: nil)
        nlLog("[AwayEpisode] ■ end (\(reason))", level: .info)
    }
}
