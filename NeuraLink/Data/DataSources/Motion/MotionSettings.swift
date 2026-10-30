//
//  MotionSettings.swift
//  NeuraLink
//
//  The user's switch for generated body motion, and the flag the tool list
//  reads on any thread: both in UserDefaults, the switch under the Autonomy
//  screen's "Talking" card. SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor +
//  @Observable, so storage is explicit backing fields.
//  See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Observation

@Observable
final class MotionSettings {
    static let shared = MotionSettings()

    static let enabledKey = "motion.generated.enabled"
    /// Written by the coordinator when the model files are present, read by
    /// `AppFunctionTool.all` (any thread) to decide whether to offer the tool.
    static let modelsReadyKey = "motion.generated.modelsReady"

    @ObservationIgnored private var _isEnabled: Bool

    private init() {
        _isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    /// Generate body motion for each spoken reply (OpenAI voice mode).
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
            MotionStreamCoordinator.shared.refreshAvailability()
        }
    }

    /// Whether the Realtime session should offer `perform_motion`: the
    /// switch is on and the model files are on the device.
    nonisolated static var offersTool: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: enabledKey) && defaults.bool(forKey: modelsReadyKey)
    }
}
