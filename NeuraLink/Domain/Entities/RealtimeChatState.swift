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
    /// Realtime session dropped; automatic reconnect attempt N in progress.
    case reconnecting(attempt: Int)
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .reconnecting(let attempt): return "Reconnecting… (\(attempt))"
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
    /// Identity key: the model's file stem. Memory banks, mental models and
    /// saved looks are filed under it, so it must stay stable.
    var selectedCharacterName: String = ""
    /// What to CALL the character. An imported model can be renamed, and
    /// its file stem keeps the name it was imported under — which is how
    /// "Othinus" ended up remembered as "Dedicatus_2". Falls back to the
    /// file stem when nothing else is set.
    var selectedCharacterDisplayName: String = ""

    /// The name to use in prompts and anything the user reads.
    var characterDisplayName: String {
        selectedCharacterDisplayName.isEmpty ? selectedCharacterName : selectedCharacterDisplayName
    }

    /// File stem → display name, mirrored out of the registry so prompt
    /// builders can resolve a name without hopping to the main actor. The
    /// registry itself is MainActor-isolated and these run wherever memory
    /// work happens.
    nonisolated(unsafe) private static var displayNames: [String: String] = [:]

    /// Refreshes that mirror. The entries are passed in rather than read
    /// back from `VRMModelRegistry.shared`: the registry calls this from its
    /// own refresh, and reaching for `shared` there re-enters it while it is
    /// still initialising.
    nonisolated static func refreshDisplayNames(_ entries: [(name: String, displayName: String)]) {
        displayNames = Dictionary(
            entries.map { ($0.name.lowercased(), $0.displayName) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Display name for a stored character key. Memory banks, mental models
    /// and follow-ups all carry the file stem, so anything turning one into
    /// prompt text has to resolve it — otherwise a renamed import is
    /// addressed by the name it was imported under.
    nonisolated static func displayName(for character: String) -> String {
        guard !character.isEmpty else { return "" }
        return (displayNames[character.lowercased()] ?? character).capitalized
    }
    /// Token usage of the live Realtime session and of the last one that ended.
    var sessionUsage = RealtimeUsageMeter()
    var currentEmotion: String = "neutral"
    var emotionDuration: Float = 0
    private var lastParsedIndex: Int = 0

    // UI Controls
    var showSettings: Bool = false
    var showUserSettings: Bool = false
    var showRelationshipBar: Bool = false
    var isUIHidden: Bool = false
    /// Right-side chat-history sidebar (ChatGPT-style).
    var showChatSidebar: Bool = false
    /// When non-nil, the read-only transcript for this past conversation is shown.
    var viewingConversationID: Int64? = nil

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
