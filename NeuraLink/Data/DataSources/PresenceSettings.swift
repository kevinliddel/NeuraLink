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
    private static let keepTalkingKey = "com.neuralink.presence.keepTalkingInBackground"
    private static let backgroundIdleKey = "com.neuralink.presence.backgroundIdleMinutes"
    private static let showWidgetsKey = "com.neuralink.presence.showWidgets"
    private static let followUpsKey = "com.neuralink.presence.followUps"

    @ObservationIgnored private var _isPresenceEnabled: Bool = false
    @ObservationIgnored private var _isNotificationsEnabled: Bool = false
    @ObservationIgnored private var _isProactiveEngagementEnabled: Bool = false
    @ObservationIgnored private var _absenceGreetingHours: Double = 6
    @ObservationIgnored private var _silenceSmallTalkSec: Double = 90
    @ObservationIgnored private var _keepTalkingInBackground: Bool = false
    @ObservationIgnored private var _backgroundIdleMinutes: Double = 10
    @ObservationIgnored private var _showWidgets: Bool = true
    @ObservationIgnored private var _followUpsEnabled: Bool = true

    private init() {
        let defaults = UserDefaults.standard
        _isPresenceEnabled = defaults.bool(forKey: Self.enabledKey)
        _isNotificationsEnabled = defaults.bool(forKey: Self.notificationsKey)
        _isProactiveEngagementEnabled = defaults.bool(forKey: Self.proactiveKey)
        _absenceGreetingHours = defaults.object(forKey: Self.absenceHoursKey) as? Double ?? 6
        _silenceSmallTalkSec = defaults.object(forKey: Self.silenceSecKey) as? Double ?? 90
        _keepTalkingInBackground = defaults.bool(forKey: Self.keepTalkingKey)
        _backgroundIdleMinutes = defaults.object(forKey: Self.backgroundIdleKey) as? Double ?? 10
        _showWidgets = defaults.object(forKey: Self.showWidgetsKey) as? Bool ?? true
        _followUpsEnabled = defaults.object(forKey: Self.followUpsKey) as? Bool ?? true
    }

    /// Character-initiated follow-ups on dated plans (docs/COMPANION_DEPTH_PLAN.md §D1).
    var followUpsEnabled: Bool {
        get {
            access(keyPath: \.followUpsEnabled)
            return _followUpsEnabled
        }
        set {
            withMutation(keyPath: \.followUpsEnabled) {
                _followUpsEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.followUpsKey)
            }
        }
    }

    /// Home / lock-screen widgets read a small snapshot (opener, relationship
    /// label, one remembered line) from the App Group. Off deletes it.
    var showWidgets: Bool {
        get {
            access(keyPath: \.showWidgets)
            return _showWidgets
        }
        set {
            withMutation(keyPath: \.showWidgets) {
                _showWidgets = newValue
                UserDefaults.standard.set(newValue, forKey: Self.showWidgetsKey)
            }
            CompanionSnapshotWriter.shared.scheduleRefresh()
        }
    }

    /// Keep an active voice session running with the screen off / in other
    /// apps (docs/PRESENCE_BEYOND_APP_PLAN.md §P1). Opt-in: the mic stays on.
    var keepTalkingInBackground: Bool {
        get {
            access(keyPath: \.keepTalkingInBackground)
            return _keepTalkingInBackground
        }
        set {
            withMutation(keyPath: \.keepTalkingInBackground) {
                _keepTalkingInBackground = newValue
                UserDefaults.standard.set(newValue, forKey: Self.keepTalkingKey)
            }
        }
    }

    /// Minutes without user speech after which a background session ends.
    var backgroundIdleMinutes: Double {
        get {
            access(keyPath: \.backgroundIdleMinutes)
            return _backgroundIdleMinutes
        }
        set {
            withMutation(keyPath: \.backgroundIdleMinutes) {
                _backgroundIdleMinutes = newValue
                UserDefaults.standard.set(newValue, forKey: Self.backgroundIdleKey)
            }
        }
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
