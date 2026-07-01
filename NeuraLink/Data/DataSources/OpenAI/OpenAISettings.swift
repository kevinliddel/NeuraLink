//
//  OpenAISettings.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import SwiftUI

/// Manages the persistent settings for OpenAI integration.
///
/// Uses the explicit `@ObservationIgnored` + `access(keyPath:)` / `withMutation(keyPath:)`
/// pattern rather than `didSet` on stored properties. With Xcode 26 / Swift 6.2's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and the `@Observable` macro, `didSet`
/// observers on stored properties fire during the very first `self.x = ...`
/// assignment in `init` (because the macro turns those properties into computed
/// accessors backed by `_x`). The mutual-exclusion side effects in `isEnabled`
/// and `isLocalLLMEnabled` setters were re-firing during init and overwriting
/// values being read from `UserDefaults` — which the user observed as "settings
/// don't persist after the security commit".
@Observable
final class OpenAISettings {
    static let shared = OpenAISettings()

    // MARK: - UserDefaults Keys (static to avoid early self-access in init)

    /// Legacy UserDefaults key — kept for the one-shot migration that moves
    /// the value into the Keychain via `SecureStore`. Do not read/write it
    /// outside `migrateAPIKeyToKeychainIfNeeded()`.
    private static let legacyAPIKeyUserDefaultsKey = "com.neuralink.openai.apiKey"
    private static let apiKeyKeychainMigrationFlag = "com.neuralink.migration.apiKeyKeychain.v1"
    private static let enabledKey = "com.neuralink.openai.enabled"
    private static let localLLMEnabledKey = "com.neuralink.localllm.enabled"
    private static let vadEnabledKey = "com.neuralink.openai.vadEnabled"
    private static let proactiveVisionEnabledKey = "com.neuralink.openai.proactiveVisionEnabled"
    private static let proactiveVisionIntervalKey = "com.neuralink.openai.proactiveVisionIntervalSec"
    private static let proactiveVisionCooldownKey = "com.neuralink.openai.proactiveVisionCooldownSec"
    private static let proactiveVisionOnlyUnlockedKey = "com.neuralink.openai.proactiveVisionOnlyUnlocked"
    private static let proactiveVisionOnlyForegroundKey = "com.neuralink.openai.proactiveVisionOnlyForeground"
    private static let proactiveVisionPrivateModeKey = "com.neuralink.openai.proactiveVisionPrivateMode"
    private static let proactiveVisionAllowPiPKey = "com.neuralink.openai.proactiveVisionAllowPiP"
    private static let migrationV2Key = "com.neuralink.migration.onDemandLLM.v1"

    // MARK: - Backing Storage

    @ObservationIgnored private var _apiKey: String = ""
    @ObservationIgnored private var _isEnabled: Bool = false
    @ObservationIgnored private var _isLocalLLMEnabled: Bool = false
    @ObservationIgnored private var _isVADEnabled: Bool = false
    @ObservationIgnored private var _isProactiveVisionEnabled: Bool = false
    @ObservationIgnored private var _proactiveVisionIntervalSec: Double = 20
    @ObservationIgnored private var _proactiveVisionCooldownAfterSpeechSec: Double = 12
    @ObservationIgnored private var _proactiveVisionOnlyWhenUnlocked: Bool = true
    @ObservationIgnored private var _proactiveVisionOnlyInForeground: Bool = true
    @ObservationIgnored private var _isProactiveVisionPrivateModeEnabled: Bool = false
    @ObservationIgnored private var _proactiveVisionAllowInPiP: Bool = false

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard

        // One-time migration: previous builds defaulted isLocalLLMEnabled to true and
        // called preload() at launch. Reset it so the model is never loaded until the
        // user explicitly enables it in Settings after the on-demand update.
        if !defaults.bool(forKey: Self.migrationV2Key) {
            defaults.set(false, forKey: Self.localLLMEnabledKey)
            defaults.set(true, forKey: Self.migrationV2Key)
        }

        // Move the API key off `UserDefaults` and into the
        // Keychain. Must run before reading `_apiKey` so the Keychain is
        // populated by the time the property initializes.
        Self.migrateAPIKeyToKeychainIfNeeded()

        // Direct backing-storage assignment bypasses the setter/withMutation
        // path, so no mutual-exclusion side effects fire during init.
        _apiKey = (try? SecureStore.get(.openAIAPIKey)) ?? ""
        _isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        _isLocalLLMEnabled = defaults.object(forKey: Self.localLLMEnabledKey) as? Bool ?? false
        _isVADEnabled = defaults.bool(forKey: Self.vadEnabledKey)
        _isProactiveVisionEnabled = defaults.bool(forKey: Self.proactiveVisionEnabledKey)
        _proactiveVisionIntervalSec = defaults.object(forKey: Self.proactiveVisionIntervalKey) as? Double ?? 20
        _proactiveVisionCooldownAfterSpeechSec = defaults.object(forKey: Self.proactiveVisionCooldownKey) as? Double ?? 12
        _proactiveVisionOnlyWhenUnlocked = defaults.object(forKey: Self.proactiveVisionOnlyUnlockedKey) as? Bool ?? true
        _proactiveVisionOnlyInForeground = defaults.object(forKey: Self.proactiveVisionOnlyForegroundKey) as? Bool ?? true
        _isProactiveVisionPrivateModeEnabled = defaults.object(forKey: Self.proactiveVisionPrivateModeKey) as? Bool ?? false
        _proactiveVisionAllowInPiP = defaults.object(forKey: Self.proactiveVisionAllowPiPKey) as? Bool ?? false
    }

    // MARK: - Observed Properties

    var apiKey: String {
        get {
            access(keyPath: \.apiKey)
            return _apiKey
        }
        set {
            withMutation(keyPath: \.apiKey) {
                _apiKey = newValue
                persistAPIKey()
            }
        }
    }

    var isEnabled: Bool {
        get {
            access(keyPath: \.isEnabled)
            return _isEnabled
        }
        set {
            let oldValue = _isEnabled
            withMutation(keyPath: \.isEnabled) {
                _isEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            }
            if newValue {
                isLocalLLMEnabled = false
                if hasValidKey {
                    OpenAIRealtimeManager.shared.connect()
                }
            } else if oldValue {
                OpenAIRealtimeManager.shared.disconnect()
            }
        }
    }

    var isLocalLLMEnabled: Bool {
        get {
            access(keyPath: \.isLocalLLMEnabled)
            return _isLocalLLMEnabled
        }
        set {
            let oldValue = _isLocalLLMEnabled
            withMutation(keyPath: \.isLocalLLMEnabled) {
                _isLocalLLMEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.localLLMEnabledKey)
            }
            if newValue {
                isEnabled = false
                LocalLLMManager.shared.startListening()
            } else if oldValue {
                LocalLLMManager.shared.unload()
            }
        }
    }

    var isVADEnabled: Bool {
        get {
            access(keyPath: \.isVADEnabled)
            return _isVADEnabled
        }
        set {
            withMutation(keyPath: \.isVADEnabled) {
                _isVADEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.vadEnabledKey)
            }
        }
    }

    var isProactiveVisionEnabled: Bool {
        get {
            access(keyPath: \.isProactiveVisionEnabled)
            return _isProactiveVisionEnabled
        }
        set {
            withMutation(keyPath: \.isProactiveVisionEnabled) {
                _isProactiveVisionEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveVisionEnabledKey)
            }
            if newValue {
                ProactiveVisionManager.shared.start()
            } else {
                ProactiveVisionManager.shared.stop()
            }
        }
    }

    var proactiveVisionIntervalSec: Double {
        get {
            access(keyPath: \.proactiveVisionIntervalSec)
            return _proactiveVisionIntervalSec
        }
        set {
            withMutation(keyPath: \.proactiveVisionIntervalSec) {
                _proactiveVisionIntervalSec = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveVisionIntervalKey)
            }
        }
    }

    var proactiveVisionCooldownAfterSpeechSec: Double {
        get {
            access(keyPath: \.proactiveVisionCooldownAfterSpeechSec)
            return _proactiveVisionCooldownAfterSpeechSec
        }
        set {
            withMutation(keyPath: \.proactiveVisionCooldownAfterSpeechSec) {
                _proactiveVisionCooldownAfterSpeechSec = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveVisionCooldownKey)
            }
        }
    }

    var proactiveVisionOnlyWhenUnlocked: Bool {
        get {
            access(keyPath: \.proactiveVisionOnlyWhenUnlocked)
            return _proactiveVisionOnlyWhenUnlocked
        }
        set {
            withMutation(keyPath: \.proactiveVisionOnlyWhenUnlocked) {
                _proactiveVisionOnlyWhenUnlocked = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveVisionOnlyUnlockedKey)
            }
        }
    }

    var proactiveVisionOnlyInForeground: Bool {
        get {
            access(keyPath: \.proactiveVisionOnlyInForeground)
            return _proactiveVisionOnlyInForeground
        }
        set {
            withMutation(keyPath: \.proactiveVisionOnlyInForeground) {
                _proactiveVisionOnlyInForeground = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveVisionOnlyForegroundKey)
            }
        }
    }

    /// Disables proactive vision regardless of other toggles (privacy quick-kill).
    var isProactiveVisionPrivateModeEnabled: Bool {
        get {
            access(keyPath: \.isProactiveVisionPrivateModeEnabled)
            return _isProactiveVisionPrivateModeEnabled
        }
        set {
            withMutation(keyPath: \.isProactiveVisionPrivateModeEnabled) {
                _isProactiveVisionPrivateModeEnabled = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveVisionPrivateModeKey)
            }
        }
    }

    /// Allows proactive vision loop while PiP is active (camera frames only).
    var proactiveVisionAllowInPiP: Bool {
        get {
            access(keyPath: \.proactiveVisionAllowInPiP)
            return _proactiveVisionAllowInPiP
        }
        set {
            withMutation(keyPath: \.proactiveVisionAllowInPiP) {
                _proactiveVisionAllowInPiP = newValue
                UserDefaults.standard.set(newValue, forKey: Self.proactiveVisionAllowPiPKey)
            }
        }
    }

    var hasValidKey: Bool {
        !_apiKey.isEmpty && _apiKey.starts(with: "sk-")
    }

    // MARK: - Keychain Persistence

    /// Writes the current `apiKey` value to the Keychain via `SecureStore`.
    /// Empty values delete the Keychain item rather than storing a zero-length
    /// blob, so a Keychain dump on a "no key configured" device shows nothing.
    private func persistAPIKey() {
        do {
            if _apiKey.isEmpty {
                try SecureStore.delete(.openAIAPIKey)
            } else {
                try SecureStore.set(_apiKey, for: .openAIAPIKey)
            }
        } catch {
            nlLog(
                "[OpenAISettings] Failed to persist API key to Keychain: \(error)",
                level: .error)
        }
    }

    /// One-shot migration that copies an existing plaintext API key out of
    /// `UserDefaults` into the Keychain, then deletes the `UserDefaults` entry.
    /// Idempotent — runs only on the first launch after the upgrade.
    ///
    /// If the Keychain write fails (e.g. transient `errSecInteractionNotAllowed`
    /// during a background launch before first unlock) we deliberately do
    /// **not** set the completion flag, so the migration retries on the next
    /// launch instead of silently dropping the user's key.
    private static func migrateAPIKeyToKeychainIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: apiKeyKeychainMigrationFlag) else { return }

        let legacyValue = defaults.string(forKey: legacyAPIKeyUserDefaultsKey) ?? ""

        if !legacyValue.isEmpty {
            do {
                try SecureStore.set(legacyValue, for: .openAIAPIKey)
                nlLog(
                    "[OpenAISettings] Migrated API key from UserDefaults to Keychain.",
                    level: .info)
            } catch {
                nlLog(
                    "[OpenAISettings] API key Keychain migration failed, will retry: \(error)",
                    level: .error)
                return
            }
        }

        defaults.removeObject(forKey: legacyAPIKeyUserDefaultsKey)
        defaults.set(true, forKey: apiKeyKeychainMigrationFlag)
    }
}
