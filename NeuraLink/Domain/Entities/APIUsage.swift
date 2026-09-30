//
//  APIUsage.swift
//  NeuraLink
//
//  One metered OpenAI call and its aggregates, for the Usage dashboard
//  (docs/API_USAGE.md). Token counts are exactly what OpenAI reported in
//  each response's `usage`; spend is an estimate from the list prices in
//  OpenAIModelCatalog.
//
//  Created by Dedicatus on 30/09/2026.
//

import Foundation

/// Which OpenAI surface a call went through.
nonisolated enum UsageSource: String, CaseIterable, Identifiable, Sendable {
    case voice, transcription, text, vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voice: return "Voice"
        case .transcription: return "Transcription"
        case .text: return "Background"
        case .vision: return "Vision"
        }
    }

    var symbol: String {
        switch self {
        case .voice: return "waveform"
        case .transcription: return "text.bubble"
        case .text: return "gearshape.2"
        case .vision: return "eye"
        }
    }
}

/// Token counts for one call — or, summed, for many.
nonisolated struct UsageRecord: Equatable, Sendable {
    var source: UsageSource
    var model: String
    /// What the call was for ("reflection", "title", "memory", …).
    var purpose: String = ""
    var inputTokens = 0
    var outputTokens = 0
    var cachedInputTokens = 0
    var audioInputTokens = 0
    var audioOutputTokens = 0
    /// Duration-billed transcription (whisper-style models report seconds).
    var audioSeconds: Double = 0

    var totalTokens: Int { inputTokens + outputTokens }
    var isEmpty: Bool { totalTokens == 0 && audioSeconds == 0 }

    /// Spend at list price (USD); 0 for a model without a catalog price.
    /// Cached-input discounts are not applied, so this errs slightly high.
    var estimatedCost: Double {
        guard let price = OpenAIModelCatalog.pricing(for: model) else { return 0 }
        let textIn = Double(max(0, inputTokens - audioInputTokens))
        let textOut = Double(max(0, outputTokens - audioOutputTokens))
        let tokens = textIn * price.input + textOut * price.output
            + Double(audioInputTokens) * price.audioInput + Double(audioOutputTokens) * price.audioOutput
        return tokens / 1_000_000 + audioSeconds / 60 * price.perMinute
    }

    mutating func add(_ other: UsageRecord) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cachedInputTokens += other.cachedInputTokens
        audioInputTokens += other.audioInputTokens
        audioOutputTokens += other.audioOutputTokens
        audioSeconds += other.audioSeconds
    }

    // MARK: - Parsing OpenAI `usage` payloads

    /// Chat Completions: `prompt_tokens` / `completion_tokens`.
    static func chatCompletions(
        usage: [String: Any], source: UsageSource, model: String, purpose: String
    ) -> UsageRecord {
        var record = UsageRecord(source: source, model: model, purpose: purpose)
        record.inputTokens = usage["prompt_tokens"] as? Int ?? 0
        record.outputTokens = usage["completion_tokens"] as? Int ?? 0
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            record.cachedInputTokens = details["cached_tokens"] as? Int ?? 0
        }
        return record
    }

    /// Realtime `response.done`: `input_tokens` / `output_tokens` plus
    /// audio and cached splits in the `*_token_details` objects.
    static func realtimeResponse(usage: [String: Any], model: String) -> UsageRecord {
        var record = UsageRecord(source: .voice, model: model, purpose: "conversation")
        record.inputTokens = usage["input_tokens"] as? Int ?? 0
        record.outputTokens = usage["output_tokens"] as? Int ?? 0
        if let details = usage["input_token_details"] as? [String: Any] {
            record.audioInputTokens = details["audio_tokens"] as? Int ?? 0
            record.cachedInputTokens = details["cached_tokens"] as? Int ?? 0
        }
        if let details = usage["output_token_details"] as? [String: Any] {
            record.audioOutputTokens = details["audio_tokens"] as? Int ?? 0
        }
        return record
    }

    /// Realtime input transcription: token-billed (`"type": "tokens"`) or
    /// duration-billed (`"type": "duration"`, `seconds`). Transcription
    /// input is audio, so its input tokens are all audio tokens unless the
    /// payload splits them.
    static func transcription(usage: [String: Any], model: String) -> UsageRecord {
        var record = UsageRecord(source: .transcription, model: model, purpose: "transcription")
        if usage["type"] as? String == "duration" {
            record.audioSeconds = usage["seconds"] as? Double ?? Double(usage["seconds"] as? Int ?? 0)
            return record
        }
        record.inputTokens = usage["input_tokens"] as? Int ?? 0
        record.outputTokens = usage["output_tokens"] as? Int ?? 0
        let details = usage["input_token_details"] as? [String: Any]
        record.audioInputTokens = details?["audio_tokens"] as? Int ?? record.inputTokens
        return record
    }
}

/// Every call in one time bucket (hour or day) sharing source, model and
/// purpose, summed.
nonisolated struct UsageBucket: Equatable, Identifiable, Sendable {
    let start: Date
    let requests: Int
    let totals: UsageRecord

    var id: String { "\(start.timeIntervalSince1970)|\(totals.source.rawValue)|\(totals.model)|\(totals.purpose)" }
}
