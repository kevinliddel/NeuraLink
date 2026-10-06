//
//  PhoneEpisode.swift
//  NeuraLink
//
//  The companion's "let me check my phone" moment. While a phone-worthy
//  tool runs and she reads its result back, the body plays
//  checking_phone.vrma with gaze tracking off, so the clip's head-down
//  tilt toward the hand shows instead of being overwritten by look-at. The
//  3D phone prop will ride the same episode once the engine can draw it.
//
//  The episode begins in AppFunctionExecutor before the skill runs and ends
//  when the spoken result finishes — the moment the 2D PhoneWidget slides
//  in, a 3D-to-2D hand-off — or on any cancel path (barge-in, teardown,
//  engine stop, character switch), or at the safety cap.
//
//  Created by Dedicatus on 06/10/2026.
//

import Foundation

/// Which tools count and how long an episode may run. Framework-free and
/// unit-tested; the scene state owns one and advances it per frame.
nonisolated struct PhoneEpisodePolicy: Equatable {
    static let clipName = "checking_phone"

    /// Tools she looks up on her phone: the PhoneWidget card tools plus
    /// reminders. Never emotion, camera, photoshoot, song recognition or
    /// the memory tools — none of those are phone moments.
    static let tools: Set<String> = [
        AppFunctionTool.getWeather, AppFunctionTool.searchWeb, AppFunctionTool.playMusic,
        AppFunctionTool.openApp, AppFunctionTool.createNote, AppFunctionTool.createReminder
    ]

    /// Longest the episode may hold the body without a stop. A tool call
    /// plus its spoken result stays well under this; the 2D widget's own
    /// auto-dismiss is the same 45 s.
    var maxHold: Float = 45
    private(set) var isActive = false
    private(set) var elapsed: Float = 0

    static func involvesPhone(_ toolName: String) -> Bool {
        tools.contains(toolName)
    }

    /// True on idle → active. False when already active: a chained tool
    /// call joins the running episode instead of restarting the clip.
    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        elapsed = 0
        return true
    }

    /// True only when an episode was active; a second stop is a no-op.
    mutating func end() -> Bool {
        guard isActive else { return false }
        isActive = false
        elapsed = 0
        return true
    }

    /// Advances the hold. True on the one frame the cap is crossed; the
    /// caller ends the episode.
    mutating func tick(dt: Float) -> Bool {
        guard isActive else { return false }
        let before = elapsed
        elapsed += dt
        return before < maxHold && elapsed >= maxHold
    }
}

/// App-wide switch the backends flip; the scene state observes it.
@MainActor
enum PhoneEpisode {
    static let didBegin = Notification.Name("NeuraLink.PhoneEpisode.didBegin")
    static let didEnd = Notification.Name("NeuraLink.PhoneEpisode.didEnd")

    /// True between begin and end. The backends read it when a response
    /// ends: a reminder queues no PhoneWidget action, so without this flag
    /// nothing would bring its episode to a close.
    private(set) static var isActive = false

    /// True from begin until the skill returns. A response that ends while
    /// the tool is still running (a user turn opened during a slow weather
    /// fetch or a reminders permission alert) is not the spoken result and
    /// must not put the phone away.
    private(set) static var isRunningTool = false

    /// Bumped on every begin. An after-speech timer armed for one tool call
    /// captures it, so a stale timer cannot end the episode a newer call
    /// has joined.
    private(set) static var generation = 0

    /// Always re-posts, even mid-episode: the scene's policy ignores a
    /// second begin, but a scene that lost the episode — a safety-cap
    /// expiry, a character switch — picks the next tool call back up.
    static func begin(tool: String) {
        isActive = true
        isRunningTool = true
        generation &+= 1
        NotificationCenter.default.post(name: didBegin, object: nil, userInfo: ["tool": tool])
        nlLog("[PhoneEpisode] ▶ begin (\(tool))", level: .info)
    }

    /// The skill returned; the result is about to be spoken.
    static func toolFinished() {
        isRunningTool = false
    }

    static func end(reason: String) {
        guard isActive else { return }
        isActive = false
        isRunningTool = false
        NotificationCenter.default.post(name: didEnd, object: nil)
        nlLog("[PhoneEpisode] ■ end (\(reason))", level: .info)
    }

    /// Ends only the episode `generation` was captured from; a timer that
    /// outlived its tool call is a no-op.
    static func end(reason: String, generation expected: Int) {
        guard expected == generation else {
            nlLog("[PhoneEpisode] stale end ignored (\(reason))", level: .debug)
            return
        }
        end(reason: reason)
    }
}
