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
        
        self.apiKey = UserDefaults.standard.string(forKey: "com.neuralink.openai.apiKey") ?? ""
        self.isEnabled = UserDefaults.standard.object(forKey: "com.neuralink.openai.enabled") as? Bool ?? false
        self.isLocalLLMEnabled = UserDefaults.standard.object(forKey: "com.neuralink.localllm.enabled") as? Bool ?? false
        self.isVADEnabled = UserDefaults.standard.bool(forKey: "com.neuralink.openai.vadEnabled")
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
    
    var hasValidKey: Bool {
        !apiKey.isEmpty && apiKey.starts(with: "sk-")
    }
}
