//
//  GroundingSettings.swift
//  NeuraLink
//
//  Opt-in toggles for daily grounding (docs/LIVING_COMPANION.md): calendar
//  events and HealthKit sleep in the Companion State block. Same storage
//  idiom as PresenceSettings: explicit `_x` backing + access/withMutation,
//  never `didSet`.
//
//  Created by Dedicatus on 15/10/2026.
//

import Foundation

@Observable
final class GroundingSettings {
    static let shared = GroundingSettings()

    private static let calendarKey = "com.neuralink.grounding.calendar"
    private static let sleepKey = "com.neuralink.grounding.sleep"

    @ObservationIgnored private var _isCalendarEnabled = false
    @ObservationIgnored private var _isSleepEnabled = false

    private init() {
        let defaults = UserDefaults.standard
        _isCalendarEnabled = defaults.bool(forKey: Self.calendarKey)
        _isSleepEnabled = defaults.bool(forKey: Self.sleepKey)
    }

    /// The next 12 hours of calendar events reach the persona.
    var isCalendarEnabled: Bool {
        get {
            access(keyPath: \.isCalendarEnabled)
            return _isCalendarEnabled
        }
        set {
            withMutation(keyPath: \.isCalendarEnabled) {
                _isCalendarEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.calendarKey)
            }
        }
    }

    /// Last night's sleep (HealthKit) reaches the persona when it was short.
    var isSleepEnabled: Bool {
        get {
            access(keyPath: \.isSleepEnabled)
            return _isSleepEnabled
        }
        set {
            withMutation(keyPath: \.isSleepEnabled) {
                _isSleepEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.sleepKey)
            }
        }
    }
}
