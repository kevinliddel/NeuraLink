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
    private static let migrationV2Key = "com.neuralink.migration.onDemandLLM.v1"

    init() {
        // One-time migration: previous builds defaulted isLocalLLMEnabled to true and
        // called preload() at launch. Reset it so the model is never loaded until the
        // user explicitly enables it in Settings after the on-demand update.
        if !UserDefaults.standard.bool(forKey: Self.migrationV2Key) {
            UserDefaults.standard.set(false, forKey: localLLMEnabledKey)
            UserDefaults.standard.set(true, forKey: Self.migrationV2Key)
        }
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyPrefix) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyPrefix) }
    }
    
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
        set { 
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                isLocalLLMEnabled = false
            }
        }
    }
    
    var isLocalLLMEnabled: Bool {
        get { UserDefaults.standard.object(forKey: localLLMEnabledKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: localLLMEnabledKey)
            if newValue {
                isEnabled = false
            } else {
                LocalLLMManager.shared.unload()
            }
        }
    }
    
    var isVADEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: vadEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: vadEnabledKey) }
    }
    
    var hasValidKey: Bool {
        !apiKey.isEmpty && apiKey.starts(with: "sk-")
    }
}
