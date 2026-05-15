//
//  MemorySettings.swift
//  NeuraLink
//
//  User controls for long-term memory storage (RAG + chat timeline).
//

import Foundation
import Observation

@Observable
final class MemorySettings {
    static let shared = MemorySettings()

    private enum Key {
        static let isEnabled = "com.neuralink.memory.enabled"
        static let storeAIResponses = "com.neuralink.memory.store_ai"
        static let autoForgetDays = "com.neuralink.memory.autoforget_days"
    }

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// If false, only user messages are stored into vector memory and the timeline.
    var storeAIResponses: Bool {
        didSet { UserDefaults.standard.set(storeAIResponses, forKey: Key.storeAIResponses) }
    }

    /// 0 disables auto-forget. Otherwise prune items older than N days (pinned items are kept).
    var autoForgetDays: Int {
        didSet { UserDefaults.standard.set(autoForgetDays, forKey: Key.autoForgetDays) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Key.isEnabled) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Key.isEnabled)
        }

        if UserDefaults.standard.object(forKey: Key.storeAIResponses) == nil {
            storeAIResponses = true
        } else {
            storeAIResponses = UserDefaults.standard.bool(forKey: Key.storeAIResponses)
        }

        autoForgetDays = UserDefaults.standard.integer(forKey: Key.autoForgetDays)
    }
}
