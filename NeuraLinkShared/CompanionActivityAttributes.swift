//
//  CompanionActivityAttributes.swift
//  NeuraLink (app + NeuraLinkWidgets)
//
//  Live Activity payload for an active voice session
//  (docs/PRESENCE_BEYOND_APP_PLAN.md §P2). Static: who; dynamic: what the
//  session is doing and the last line said. Compiled into both targets.
//
//  Created by Dedicatus on 27/09/2026.
//

import ActivityKit
import Foundation

nonisolated struct CompanionActivityAttributes: ActivityAttributes {
    nonisolated enum Phase: String, Codable, Hashable, Sendable {
        case listening, thinking, speaking, reconnecting

        var label: String {
            switch self {
            case .listening: return "Listening"
            case .thinking: return "Thinking…"
            case .speaking: return "Speaking"
            case .reconnecting: return "Reconnecting…"
            }
        }

        var symbol: String {
            switch self {
            case .listening: return "waveform"
            case .thinking: return "ellipsis"
            case .speaking: return "speaker.wave.2.fill"
            case .reconnecting: return "arrow.triangle.2.circlepath"
            }
        }
    }

    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        /// Last completed assistant line, trimmed to 80 characters.
        var lastLine: String
    }

    let character: String
    let displayName: String
    let thumbnailFile: String?
    let startedAt: Date
}
