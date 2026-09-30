//
//  OpenAIModelCatalog.swift
//  NeuraLink
//
//  Curated model ids for the three OpenAI roles the app uses
//  (docs/CHAT_LLM.md). A fixed list per role — every text entry is a
//  Chat Completions model with function calling + image input; realtime
//  entries are the conversational Realtime API models; transcription
//  entries are the ids a Realtime session accepts for input transcription.
//  A stored id that drops out of the catalog falls back to the default.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

nonisolated enum OpenAIModelCatalog {

    /// List price in USD per 1M tokens (or per minute for duration-billed
    /// transcription) — from developers.openai.com model pages, 2026-09-30.
    /// Feeds the Usage dashboard's spend estimate only.
    struct Pricing: Hashable, Sendable {
        var input: Double = 0
        var output: Double = 0
        var audioInput: Double = 0
        var audioOutput: Double = 0
        var perMinute: Double = 0

        static func text(_ input: Double, _ output: Double) -> Pricing {
            Pricing(input: input, output: output)
        }

        static func voice(text: (Double, Double), audio: (Double, Double)) -> Pricing {
            Pricing(input: text.0, output: text.1, audioInput: audio.0, audioOutput: audio.1)
        }

        /// Token-billed transcription: audio in, text out.
        static func transcribe(_ audioInput: Double, _ output: Double) -> Pricing {
            Pricing(input: audioInput, output: output, audioInput: audioInput)
        }

        static func minutes(_ perMinute: Double) -> Pricing {
            Pricing(perMinute: perMinute)
        }
    }

    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let note: String
        /// `reasoning_effort` sent with background text calls. Reasoning
        /// models default to "medium", which spends a short call's whole
        /// `max_completion_tokens` budget on reasoning and returns empty
        /// content (titles get 16 tokens, reflections 160). nil = not a
        /// reasoning model.
        var reasoningEffort: String?
        var pricing: Pricing?
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

    static let realtime: [Entry] = [
        Entry(id: "gpt-realtime-2.1-mini", note: "Default — fast, low cost",
              pricing: .voice(text: (0.60, 2.40), audio: (10, 20))),
        Entry(
            id: "gpt-realtime-2.1",
            note: "Best quality — reasoning, handles noise and interruptions",
            pricing: .voice(text: (4, 24), audio: (32, 64))),
        Entry(id: "gpt-realtime-2", note: "Previous generation, full size",
              pricing: .voice(text: (4, 24), audio: (32, 64))),
        Entry(id: "gpt-realtime-1.5", note: "No reasoning, 32k context",
              pricing: .voice(text: (4, 16), audio: (32, 64))),
        Entry(id: "gpt-realtime", note: "Legacy — retires January 2027",
              pricing: .voice(text: (4, 16), audio: (32, 64))),
        Entry(id: "gpt-realtime-mini", note: "Legacy, low cost — retires January 2027",
              pricing: .voice(text: (0.60, 2.40), audio: (10, 20)))
    ]

    static let transcription: [Entry] = [
        Entry(id: "gpt-4o-transcribe", note: "Default — best on names and titles",
              pricing: .transcribe(2.50, 10)),
        Entry(id: "gpt-live-transcribe", note: "Low latency, OpenAI's recommended live model",
              pricing: .minutes(0.017)),
        Entry(id: "gpt-realtime-whisper", note: "Streaming — ignores the vocabulary prompt",
              pricing: .minutes(0.017)),
        Entry(id: "gpt-4o-mini-transcribe", note: "Cheaper, slightly less accurate",
              pricing: .transcribe(1.25, 5)),
        Entry(id: "whisper-1", note: "Legacy",
              pricing: .minutes(0.006))
    ]

    static let text: [Entry] = [
        Entry(
            id: "gpt-5.6-luna", note: "Default — memory, titling, reflection",
            reasoningEffort: "none", pricing: .text(0.20, 1.20)),
        Entry(id: "gpt-5.6-terra", note: "Balanced quality and cost", reasoningEffort: "none",
              pricing: .text(2, 12)),
        Entry(id: "gpt-5.6-sol", note: "GPT-5.6 flagship", reasoningEffort: "none",
              pricing: .text(4, 20)),
        Entry(id: "gpt-6-luna", note: "Newest generation, efficient", reasoningEffort: "none",
              pricing: .text(0.10, 0.50)),
        Entry(id: "gpt-5.5", note: "Flagship for complex work", reasoningEffort: "none",
              pricing: .text(5, 30)),
        Entry(id: "gpt-5.4", note: "Capable, more affordable", reasoningEffort: "none",
              pricing: .text(2.50, 15)),
        Entry(id: "gpt-5.4-mini", note: "Strong mini, high volume", reasoningEffort: "none",
              pricing: .text(0.75, 4.50)),
        Entry(id: "gpt-5.2", note: "Previous flagship", reasoningEffort: "none",
              pricing: .text(1.75, 14)),
        Entry(id: "gpt-5.1", note: "Older GPT-5", reasoningEffort: "none",
              pricing: .text(1.25, 10)),
        Entry(
            id: "gpt-5", note: "Original GPT-5 — retires December 2026", reasoningEffort: "minimal",
            pricing: .text(1.25, 10)),
        Entry(id: "gpt-5-mini", note: "Retires December 2026", reasoningEffort: "minimal",
              pricing: .text(0.25, 2)),
        Entry(id: "gpt-4.1", note: "Smartest non-reasoning model",
              pricing: .text(2, 8)),
        Entry(id: "gpt-4.1-mini", note: "Fast, low cost",
              pricing: .text(0.40, 1.60)),
        Entry(id: "gpt-4o", note: "Higher quality",
              pricing: .text(2.50, 10)),
        Entry(id: "gpt-4o-mini", note: "Cheapest",
              pricing: .text(0.15, 0.60))
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

    /// List price for any catalog id (vision calls use text-model ids).
    static func pricing(for id: String) -> Pricing? {
        Role.allCases.lazy.compactMap { entry(for: id, role: $0)?.pricing }.first
    }

    static func entry(for id: String, role: Role) -> Entry? {
        entries(for: role).first { $0.id == id }
    }

    /// `id` when the catalog lists it for `role`, else the role default.
    static func resolved(_ id: String, role: Role) -> String {
        entry(for: id, role: role) == nil ? defaultID(for: role) : id
    }

    static func pickerItems(for role: Role) -> [String] {
        entries(for: role).map(\.id)
    }

    static func pickerTitle(for id: String) -> String { id }

    /// Effort for a background text call; nil sends none (non-reasoning).
    static func reasoningEffort(forTextModel id: String) -> String? {
        entry(for: id, role: .text)?.reasoningEffort
    }

    /// gpt-realtime-whisper rejects the transcription `prompt`.
    static func transcriptionSupportsPrompt(_ id: String) -> Bool {
        id != "gpt-realtime-whisper"
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
