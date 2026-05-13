//
//  OpenAISettings.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import SwiftUI

/// Manages the persistent settings for OpenAI integration.
@Observable
final class OpenAISettings {
    static let shared = OpenAISettings()

    // UserDefaults Keys
    private let apiKeyPrefix = "com.neuralink.openai.apiKey"
    private let enabledKey = "com.neuralink.openai.enabled"
    private let localLLMEnabledKey = "com.neuralink.localllm.enabled"
    private let vadEnabledKey = "com.neuralink.openai.vadEnabled"
    private let proactiveVisionEnabledKey = "com.neuralink.openai.proactiveVisionEnabled"
    private let proactiveVisionIntervalKey = "com.neuralink.openai.proactiveVisionIntervalSec"
    private let proactiveVisionCooldownKey = "com.neuralink.openai.proactiveVisionCooldownSec"
    private let proactiveVisionOnlyUnlockedKey = "com.neuralink.openai.proactiveVisionOnlyUnlocked"
    private let proactiveVisionOnlyForegroundKey = "com.neuralink.openai.proactiveVisionOnlyForeground"
    private let proactiveVisionPrivateModeKey = "com.neuralink.openai.proactiveVisionPrivateMode"
    private let proactiveVisionAllowPiPKey = "com.neuralink.openai.proactiveVisionAllowPiP"
    private static let migrationV2Key = "com.neuralink.migration.onDemandLLM.v1"

    init() {
        // One-time migration: previous builds defaulted isLocalLLMEnabled to true and
        // called preload() at launch. Reset it so the model is never loaded until the
        // user explicitly enables it in Settings after the on-demand update.
        if !UserDefaults.standard.bool(forKey: Self.migrationV2Key) {
            UserDefaults.standard.set(false, forKey: localLLMEnabledKey)
            UserDefaults.standard.set(true, forKey: Self.migrationV2Key)
        }
        
        self.apiKey = UserDefaults.standard.string(forKey: "com.neuralink.openai.apiKey") ?? ""
        self.isEnabled = UserDefaults.standard.object(forKey: "com.neuralink.openai.enabled") as? Bool ?? false
        self.isLocalLLMEnabled = UserDefaults.standard.object(forKey: "com.neuralink.localllm.enabled") as? Bool ?? false
        self.isVADEnabled = UserDefaults.standard.bool(forKey: "com.neuralink.openai.vadEnabled")
        self.isProactiveVisionEnabled = UserDefaults.standard.bool(forKey: "com.neuralink.openai.proactiveVisionEnabled")
        self.proactiveVisionIntervalSec = UserDefaults.standard.object(forKey: proactiveVisionIntervalKey) as? Double ?? 20
        self.proactiveVisionCooldownAfterSpeechSec = UserDefaults.standard.object(forKey: proactiveVisionCooldownKey) as? Double ?? 12
        self.proactiveVisionOnlyWhenUnlocked = UserDefaults.standard.object(forKey: proactiveVisionOnlyUnlockedKey) as? Bool ?? true
        self.proactiveVisionOnlyInForeground = UserDefaults.standard.object(forKey: proactiveVisionOnlyForegroundKey) as? Bool ?? true
        self.isProactiveVisionPrivateModeEnabled = UserDefaults.standard.object(forKey: proactiveVisionPrivateModeKey) as? Bool ?? false
        self.proactiveVisionAllowInPiP = UserDefaults.standard.object(forKey: proactiveVisionAllowPiPKey) as? Bool ?? false
    }

    var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: apiKeyPrefix) }
    }
    
    var isEnabled: Bool {
        didSet { 
            UserDefaults.standard.set(isEnabled, forKey: enabledKey)
            if isEnabled {
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
        didSet {
            UserDefaults.standard.set(isLocalLLMEnabled, forKey: localLLMEnabledKey)
            if isLocalLLMEnabled {
                isEnabled = false
                LocalLLMManager.shared.startListening()
            } else if oldValue {
                LocalLLMManager.shared.unload()
            }
        }
    }
    
    var isVADEnabled: Bool {
        didSet { UserDefaults.standard.set(isVADEnabled, forKey: vadEnabledKey) }
    }
    
    var isProactiveVisionEnabled: Bool {
        didSet { 
            UserDefaults.standard.set(isProactiveVisionEnabled, forKey: proactiveVisionEnabledKey) 
            if isProactiveVisionEnabled {
                ProactiveVisionManager.shared.start()
            } else {
                ProactiveVisionManager.shared.stop()
            }
        }
    }

    var proactiveVisionIntervalSec: Double {
        didSet { UserDefaults.standard.set(proactiveVisionIntervalSec, forKey: proactiveVisionIntervalKey) }
    }

    var proactiveVisionCooldownAfterSpeechSec: Double {
        didSet { UserDefaults.standard.set(proactiveVisionCooldownAfterSpeechSec, forKey: proactiveVisionCooldownKey) }
    }

    var proactiveVisionOnlyWhenUnlocked: Bool {
        didSet { UserDefaults.standard.set(proactiveVisionOnlyWhenUnlocked, forKey: proactiveVisionOnlyUnlockedKey) }
    }

    var proactiveVisionOnlyInForeground: Bool {
        didSet { UserDefaults.standard.set(proactiveVisionOnlyInForeground, forKey: proactiveVisionOnlyForegroundKey) }
    }

    /// Disables proactive vision regardless of other toggles (privacy quick-kill).
    var isProactiveVisionPrivateModeEnabled: Bool {
        didSet { UserDefaults.standard.set(isProactiveVisionPrivateModeEnabled, forKey: proactiveVisionPrivateModeKey) }
    }

    /// Allows proactive vision loop while PiP is active (camera frames only).
    var proactiveVisionAllowInPiP: Bool {
        didSet { UserDefaults.standard.set(proactiveVisionAllowInPiP, forKey: proactiveVisionAllowPiPKey) }
    }
    
    var hasValidKey: Bool {
        !apiKey.isEmpty && apiKey.starts(with: "sk-")
    }
}
