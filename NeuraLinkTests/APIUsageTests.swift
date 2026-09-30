//
//  APIUsageTests.swift
//  NeuraLinkTests
//
//  Usage metering + dashboard aggregation (docs/API_USAGE.md): payload
//  parsing, spend estimate, SQL bucketing and the summary filters.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("API usage", .serialized)
struct APIUsageTests {

    // MARK: - Parsing

    @Test("Chat Completions usage maps prompt/completion/cached tokens")
    func chatCompletionsParsing() {
        let record = UsageRecord.chatCompletions(
            usage: ["prompt_tokens": 1_200, "completion_tokens": 80, "prompt_tokens_details": ["cached_tokens": 1_024]],
            source: .text, model: "gpt-5.6-luna", purpose: "reflection")
        #expect(record.inputTokens == 1_200)
        #expect(record.outputTokens == 80)
        #expect(record.cachedInputTokens == 1_024)
        #expect(record.purpose == "reflection")
    }

    @Test("Realtime response usage splits audio tokens")
    func realtimeParsing() {
        let record = UsageRecord.realtimeResponse(
            usage: [
                "input_tokens": 1_000, "output_tokens": 400,
                "input_token_details": ["audio_tokens": 700, "cached_tokens": 200],
                "output_token_details": ["audio_tokens": 350]
            ],
            model: "gpt-realtime-2.1-mini")
        #expect(record.source == .voice)
        #expect(record.audioInputTokens == 700)
        #expect(record.audioOutputTokens == 350)
        #expect(record.totalTokens == 1_400)
    }

    @Test("Transcription usage handles token and duration billing")
    func transcriptionParsing() {
        let tokens = UsageRecord.transcription(
            usage: ["type": "tokens", "input_tokens": 90, "output_tokens": 12], model: "gpt-4o-transcribe")
        #expect(tokens.audioInputTokens == 90)
        #expect(tokens.outputTokens == 12)

        let duration = UsageRecord.transcription(usage: ["type": "duration", "seconds": 42], model: "whisper-1")
        #expect(duration.audioSeconds == 42)
        #expect(duration.totalTokens == 0)
        #expect(!duration.isEmpty)
    }

    // MARK: - Spend

    @Test("Spend prices text, audio and per-minute usage from the catalog")
    func estimatedCost() {
        let text = UsageRecord(source: .text, model: "gpt-4o-mini", inputTokens: 1_000_000, outputTokens: 1_000_000)
        #expect(abs(text.estimatedCost - 0.75) < 1e-9)  // 0.15 + 0.60

        var voice = UsageRecord(source: .voice, model: "gpt-realtime-2.1-mini")
        voice.inputTokens = 1_000_000
        voice.audioInputTokens = 1_000_000
        #expect(abs(voice.estimatedCost - 10) < 1e-9)  // all audio in at $10/1M

        let whisper = UsageRecord(source: .transcription, model: "whisper-1", audioSeconds: 600)
        #expect(abs(whisper.estimatedCost - 0.06) < 1e-9)  // 10 min × $0.006

        #expect(UsageRecord(source: .text, model: "not-a-model", inputTokens: 5_000).estimatedCost == 0)
    }

    @Test("Every catalog model has a price")
    func catalogPricing() {
        for role in OpenAIModelCatalog.Role.allCases {
            for entry in OpenAIModelCatalog.entries(for: role) {
                #expect(entry.pricing != nil, "\(entry.id) has no price")
            }
        }
    }

    @Test("Formatting")
    func formatting() {
        #expect(UsageFormat.tokens(812) == "812")
        #expect(UsageFormat.tokens(12_340) == "12.3k")
        #expect(UsageFormat.tokens(1_240_000) == "1.24M")
        #expect(UsageFormat.cost(0) == "$0.00")
        #expect(UsageFormat.cost(0.004) == "<$0.01")
    }

    // MARK: - Store + summary

    @Test("Stored calls bucket per day and filter by source and model")
    func storeAndSummary() {
        let store = MemoryStore.shared
        let calendar = Calendar.current
        // A fixed window far in the past so real rows never interfere.
        let base = calendar.date(from: DateComponents(year: 2001, month: 3, day: 10, hour: 12))!
        let dayBefore = calendar.date(byAdding: .day, value: -1, to: base)!
        let windowStart = calendar.date(byAdding: .day, value: -3, to: base)!
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: base)!
        clear(from: windowStart, to: windowEnd)
        defer { clear(from: windowStart, to: windowEnd) }

        store.insertUsage(UsageRecord(source: .text, model: "gpt-4o-mini", purpose: "title", inputTokens: 100, outputTokens: 10), at: base)
        store.insertUsage(UsageRecord(source: .text, model: "gpt-4o-mini", purpose: "title", inputTokens: 50, outputTokens: 5), at: base)
        store.insertUsage(UsageRecord(source: .voice, model: "gpt-realtime-2.1-mini", purpose: "conversation",
                                      inputTokens: 1_000, outputTokens: 500), at: dayBefore)

        let buckets = store.usageBuckets(from: windowStart, to: windowEnd, hourly: false)
        #expect(buckets.count == 2)
        let title = buckets.first { $0.totals.source == .text }
        #expect(title?.requests == 2)
        #expect(title?.totals.inputTokens == 150)
        #expect(title?.start == calendar.startOfDay(for: base))

        let snapshot = UsageDashboardSnapshot(
            range: .week, interval: DateInterval(start: windowStart, end: windowEnd), current: buckets, previous: [])
        let all = snapshot.summary(filter: UsageFilter())
        #expect(all.requests == 3)
        #expect(all.totals.totalTokens == 1_665)
        #expect(all.byModel.count == 2)
        #expect(all.byFeature.map(\.title).contains("Chat titles"))
        #expect(all.points.count == 2)

        let voiceOnly = snapshot.summary(filter: UsageFilter(source: .voice))
        #expect(voiceOnly.requests == 1)
        #expect(voiceOnly.models == ["gpt-realtime-2.1-mini"])

        let byModel = snapshot.summary(filter: UsageFilter(model: "gpt-4o-mini"))
        #expect(byModel.totals.totalTokens == 165)
    }

    @Test("Change vs the previous window")
    func periodChange() {
        var summary = UsageSummary()
        summary.cost = 1.5
        summary.previousCost = 1.0
        #expect(abs((summary.change(for: .spend) ?? 0) - 0.5) < 1e-9)
        summary.previousCost = 0
        #expect(summary.change(for: .spend) == nil)
    }

    @Test("Ranges cover whole local days ending today")
    func rangeIntervals() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!
        let week = UsageRange.week.interval(now: now, calendar: calendar)
        #expect(week.start == calendar.date(from: DateComponents(year: 2026, month: 9, day: 24)))
        #expect(week.end == calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let previous = UsageRange.week.previousInterval(now: now, calendar: calendar)
        #expect(previous.end == week.start)
        #expect(previous.start == calendar.date(from: DateComponents(year: 2026, month: 9, day: 17)))
    }

    private func clear(from: Date, to: Date) {
        MemoryStore.shared.deleteUsage(from: from, to: to)
    }
}
