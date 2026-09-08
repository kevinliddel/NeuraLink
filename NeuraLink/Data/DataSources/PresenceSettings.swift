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

    @ObservationIgnored private var _isPresenceEnabled: Bool = false
    @ObservationIgnored private var _isNotificationsEnabled: Bool = false

    private init() {
        let defaults = UserDefaults.standard
        _isPresenceEnabled = defaults.bool(forKey: Self.enabledKey)
        _isNotificationsEnabled = defaults.bool(forKey: Self.notificationsKey)
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
}
