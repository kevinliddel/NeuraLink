//
//  PresenceSettings.swift
//  NeuraLink
//
//  Toggles for the Living Companion presence features (Phase 1,
//  docs/LIVING_COMPANION_PLAN.md). Engine-agnostic, so they live outside
//  OpenAISettings — but they follow its storage idiom exactly: explicit
//  `_x` backing + `access`/`withMutation`, NEVER `didSet` (under
//  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + @Observable, `didSet` fires
//  during init and clobbers the UserDefaults read — see
//  OpenAISettings.swift:12-21).
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation

@Observable
final class PresenceSettings {
    static let shared = PresenceSettings()

    private static let enabledKey = "com.neuralink.presence.enabled"
    private static let notificationsKey = "com.neuralink.presence.notificationsEnabled"
    private static let proactiveKey = "com.neuralink.presence.proactiveEnabled"
    private static let absenceHoursKey = "com.neuralink.presence.absenceGreetingHours"
    private static let silenceSecKey = "com.neuralink.presence.silenceSmallTalkSec"

    @ObservationIgnored private var _isPresenceEnabled: Bool = false
    @ObservationIgnored private var _isNotificationsEnabled: Bool = false
    @ObservationIgnored private var _isProactiveEngagementEnabled: Bool = false
    @ObservationIgnored private var _absenceGreetingHours: Double = 6
    @ObservationIgnored private var _silenceSmallTalkSec: Double = 90

    private init() {
        let defaults = UserDefaults.standard
        _isPresenceEnabled = defaults.bool(forKey: Self.enabledKey)
        _isNotificationsEnabled = defaults.bool(forKey: Self.notificationsKey)
        _isProactiveEngagementEnabled = defaults.bool(forKey: Self.proactiveKey)
        _absenceGreetingHours = defaults.object(forKey: Self.absenceHoursKey) as? Double ?? 6
        _silenceSmallTalkSec = defaults.object(forKey: Self.silenceSecKey) as? Double ?? 90
    }

    /// Master switch: end-of-session reflection (diary + opener). Opt-in.
    var isPresenceEnabled: Bool {
        get {
            access(keyPath: \.isPresenceEnabled)
            return _isPresenceEnabled
        }
        set {
            withMutation(keyPath: \.isPresenceEnabled) {
                _isPresenceEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
            if !newValue { CompanionNotificationScheduler.cancelPending() }
        }
    }

    /// "She's been thinking of you" local notifications. Requires the master
    /// switch; requests system authorization on first enable.
    var isNotificationsEnabled: Bool {
        get {
            access(keyPath: \.isNotificationsEnabled)
            return _isNotificationsEnabled
        }
        set {
            withMutation(keyPath: \.isNotificationsEnabled) {
                _isNotificationsEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.notificationsKey)
            }
            if newValue {
                Task { _ = await CompanionNotificationScheduler.requestAuthorization() }
            } else {
                CompanionNotificationScheduler.cancelPending()
            }
        }
    }

    /// Trigger switch for absence greetings + silence small talk (Phase 3).
    /// Independent of `isPresenceEnabled` — without reflections the greeting
    /// simply falls back to a generic warm welcome.
    var isProactiveEngagementEnabled: Bool {
        get {
            access(keyPath: \.isProactiveEngagementEnabled)
            return _isProactiveEngagementEnabled
        }
        set {
            withMutation(keyPath: \.isProactiveEngagementEnabled) {
                _isProactiveEngagementEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveKey)
            }
            if newValue {
                ProactivePresenceManager.shared.start()
            } else {
                ProactivePresenceManager.shared.stop()
            }
        }
    }

    /// Hours away before the return greeting fires.
    var absenceGreetingHours: Double {
        get {
            access(keyPath: \.absenceGreetingHours)
            return _absenceGreetingHours
        }
        set {
            withMutation(keyPath: \.absenceGreetingHours) {
                _absenceGreetingHours = newValue
                UserDefaults.standard.set(newValue, forKey: Self.absenceHoursKey)
            }
        }
    }

    /// Seconds of in-session silence before the first small talk.
    var silenceSmallTalkSec: Double {
        get {
            access(keyPath: \.silenceSmallTalkSec)
            return _silenceSmallTalkSec
        }
        set {
            withMutation(keyPath: \.silenceSmallTalkSec) {
                _silenceSmallTalkSec = newValue
                UserDefaults.standard.set(newValue, forKey: Self.silenceSecKey)
            }
        }
    }
}
