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
    private let vadEnabledKey = "com.neuralink.openai.vadEnabled"

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyPrefix) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiKeyPrefix) }
    }
    
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    
    var isVADEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: vadEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: vadEnabledKey) }
    }
    
    var hasValidKey: Bool {
        !apiKey.isEmpty && apiKey.starts(with: "sk-")
    }
}
