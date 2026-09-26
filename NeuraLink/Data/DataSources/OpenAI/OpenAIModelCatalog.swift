//
//  OpenAIModelCatalog.swift
//  NeuraLink
//
//  Curated model ids for the three OpenAI roles the app uses
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B3). The settings picker offers these
//  plus a free-text "custom" entry, so a new model never needs a rebuild.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

nonisolated enum OpenAIModelCatalog {

    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        let note: String
    }

    enum Role: String, CaseIterable, Sendable {
        case realtime, transcription, text

        var title: String {
            switch self {
            case .realtime: return "Voice model"
            case .transcription: return "Transcription model"
            case .text: return "Background text model"
            }
        }
    }

    /// Sentinel selection that reveals the free-text field.
    static let customID = "custom"

    static let realtime: [Entry] = [
        Entry(id: "gpt-realtime-2.1-mini", label: "gpt-realtime-2.1-mini", note: "Default — fast, low cost")
    ]

    static let transcription: [Entry] = [
        Entry(id: "gpt-4o-transcribe", label: "gpt-4o-transcribe", note: "Default — best on names and titles"),
        Entry(id: "gpt-4o-mini-transcribe", label: "gpt-4o-mini-transcribe", note: "Cheaper, slightly less accurate"),
        Entry(id: "whisper-1", label: "whisper-1", note: "Legacy")
    ]

    static let text: [Entry] = [
        Entry(id: "gpt-5.6-luna", label: "gpt-5.6-luna", note: "Default — memory, titling, reflection"),
        Entry(id: "gpt-4o-mini", label: "gpt-4o-mini", note: "Cheapest"),
        Entry(id: "gpt-4o", label: "gpt-4o", note: "Higher quality")
    ]

    static func entries(for role: Role) -> [Entry] {
        switch role {
        case .realtime: return realtime
        case .transcription: return transcription
        case .text: return text
        }
    }

    static func defaultID(for role: Role) -> String {
        entries(for: role).first?.id ?? ""
    }

    /// Picker items: catalog ids followed by the custom sentinel.
    static func pickerItems(for role: Role) -> [String] {
        entries(for: role).map(\.id) + [customID]
    }

    static func pickerTitle(for id: String) -> String {
        id == customID ? "Custom…" : id
    }
}

/// Token accounting for one Realtime session, fed by `response.done`
/// `usage` payloads. Logged under `[Cost]` at teardown.
nonisolated struct RealtimeUsageMeter: Sendable, Equatable {
    var responses = 0
    var inputTokens = 0
    var outputTokens = 0
    var inputAudioTokens = 0
    var outputAudioTokens = 0
    var cachedInputTokens = 0

    var totalTokens: Int { inputTokens + outputTokens }

    /// Adds one `response.done` usage dictionary (missing keys count as 0).
    mutating func add(usage: [String: Any]) {
        responses += 1
        inputTokens += usage["input_tokens"] as? Int ?? 0
        outputTokens += usage["output_tokens"] as? Int ?? 0
        if let details = usage["input_token_details"] as? [String: Any] {
            inputAudioTokens += details["audio_tokens"] as? Int ?? 0
            cachedInputTokens += details["cached_tokens"] as? Int ?? 0
        }
        if let details = usage["output_token_details"] as? [String: Any] {
            outputAudioTokens += details["audio_tokens"] as? Int ?? 0
        }
    }

    var logLine: String {
        "[Cost] realtime responses=\(responses) in=\(inputTokens) (audio \(inputAudioTokens), cached \(cachedInputTokens)) "
            + "out=\(outputTokens) (audio \(outputAudioTokens)) total=\(totalTokens)"
    }

    /// Short human string for the settings footer, e.g. "12.3k tokens".
    var summary: String {
        totalTokens >= 1_000
            ? String(format: "%.1fk tokens", Double(totalTokens) / 1_000)
            : "\(totalTokens) tokens"
    }
}
