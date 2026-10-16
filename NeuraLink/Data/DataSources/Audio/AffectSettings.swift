//
//  AffectSettings.swift
//  NeuraLink
//
//  Toggle for acoustic affect sensing (docs/LLM_VOICE.md). Same storage
//  idiom as PresenceSettings: explicit `_x` backing, never `didSet`.
//
//  Created by Dedicatus on 16/10/2026.
//

import Foundation

@Observable
final class AffectSettings {
    static let shared = AffectSettings()

    private static let enabledKey = "com.neuralink.affect.enabled"

    @ObservationIgnored private var _isEnabled = true

    private init() {
        _isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// The companion hears how the user sounds and adapts its tone.
    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return _isEnabled
        }
        set {
            withMutation(keyPath: \.isEnabled) {
                _isEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
        }
    }
}
