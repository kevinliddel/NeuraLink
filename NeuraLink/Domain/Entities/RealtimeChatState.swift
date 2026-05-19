//
//  RealtimeChatState.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import SwiftUI

/// Represents the current status of the AI Voice connection.
enum AIConnectionStatus: Equatable {
    case disconnected
    case connecting  // OpenAI WebRTC handshake
    case preparing  // Local SLM model warm-up
    case ready
    case listening
    case thinking
    case speaking
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .preparing: return "Preparing local LLMs..."
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking..."
        case .speaking: return "AI Speaking"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

/// Orchestrates the UI state for the Realtime AI Chat.
@Observable
final class RealtimeChatState {
    static let shared = RealtimeChatState()

    var status: AIConnectionStatus = .disconnected
    var userTranscript: String = ""
    var aiTranscript: String = ""
    var audioLevel: Float = 0.0  // 0.0 to 1.0
    var selectedCharacterName: String = ""
    var currentEmotion: String = "neutral"
    var emotionDuration: Float = 0
    private var lastParsedIndex: Int = 0

    // UI Controls
    var showSettings: Bool = false
    var showUserSettings: Bool = false
    var showRelationshipBar: Bool = false
    var isUIHidden: Bool = false

    func clearTranscripts() {
        userTranscript = ""
        aiTranscript = ""
        audioLevel = 0.0
        currentEmotion = "neutral"
        emotionDuration = 0
        lastParsedIndex = 0
    }

    func setError(_ message: String) {
        status = .error(message)
    }

    func triggerEmotion(_ emotion: String, duration: Float) {
        self.currentEmotion = emotion.lowercased()
        self.emotionDuration = duration
    }

    /// Parses tags like [happy:2.5] from the given text and triggers the corresponding emotion.
    /// Tracks progress to avoid re-triggering the same tag.
    func parseAndTriggerEmotion(from text: String) {
        let nsString = text as NSString
        // Auto-reset when the transcript was cleared/restarted between turns
        if nsString.length < lastParsedIndex {
            lastParsedIndex = 0
        }
        guard nsString.length > lastParsedIndex else { return }
        
        let remainingRange = NSRange(location: lastParsedIndex, length: nsString.length - lastParsedIndex)
        // nlLog("[EmotionManager] Parsing: \(nsString.substring(with: remainingRange))", level: .info)
        
        let pattern = #"(?i)\[(happy|angry|sad|relaxed|surprised|shocked|shy|embarrassed|bored|confused|wink|neutral):(\d+(?:\.\d+)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }

        let results = regex.matches(in: text, options: [], range: remainingRange)

        for result in results {
            let emotion = nsString.substring(with: result.range(at: 1))
            let durationString = nsString.substring(with: result.range(at: 2))
            if let duration = Float(durationString) {
                nlLog("[EmotionManager] Found tag: [\(emotion):\(duration)] in text", level: .info)
                triggerEmotion(emotion, duration: duration)
            }
            lastParsedIndex = result.range.upperBound
        }
    }
}
