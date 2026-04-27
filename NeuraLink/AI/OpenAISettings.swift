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
        get { UserDefaults.standard.object(forKey: localLLMEnabledKey) as? Bool ?? true }
        set { 
            UserDefaults.standard.set(newValue, forKey: localLLMEnabledKey)
            if newValue {
                isEnabled = false
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
