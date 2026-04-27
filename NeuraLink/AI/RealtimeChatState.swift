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
    case connecting   // OpenAI WebRTC handshake
    case preparing    // Local SLM model warm-up
    case ready
    case listening
    case thinking
    case speaking
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .preparing: return "Preparing local SLMs..."
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
    var audioLevel: Float = 0.0 // 0.0 to 1.0
    var selectedCharacterName: String = ""

    // UI Controls
    var showSettings: Bool = false

    func clearTranscripts() {
        userTranscript = ""
        aiTranscript = ""
        audioLevel = 0.0
    }
    
    func setError(_ message: String) {
        status = .error(message)
    }
}
