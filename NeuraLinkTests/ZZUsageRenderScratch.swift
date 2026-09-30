// TEMPORARY visual check — delete before commit.
import SwiftUI
import Testing
@testable import NeuraLink

@MainActor
@Suite("ZZ usage render scratch")
struct ZZUsageRenderScratch {
    @Test func render() throws {
        let calendar = Calendar.current
        let range = UsageRange.week
        let interval = range.interval(now: Date())
        var buckets: [UsageBucket] = []
        for day in 0..<7 {
            let start = calendar.date(byAdding: .day, value: day, to: interval.start)!
            let scale = [0.4, 1.0, 0.7, 1.6, 0.9, 2.2, 1.2][day]
            buckets.append(UsageBucket(start: start, requests: Int(40 * scale), totals: UsageRecord(
                source: .voice, model: "gpt-realtime-2.1-mini", purpose: "conversation",
                inputTokens: Int(60_000 * scale), outputTokens: Int(22_000 * scale),
                audioInputTokens: Int(45_000 * scale), audioOutputTokens: Int(18_000 * scale))))
            buckets.append(UsageBucket(start: start, requests: Int(30 * scale), totals: UsageRecord(
                source: .transcription, model: "gpt-4o-transcribe", purpose: "transcription",
                inputTokens: Int(9_000 * scale), outputTokens: Int(1_500 * scale), audioInputTokens: Int(9_000 * scale))))
            buckets.append(UsageBucket(start: start, requests: Int(12 * scale), totals: UsageRecord(
                source: .text, model: "gpt-5.6-luna", purpose: day % 2 == 0 ? "memory" : "reflection",
                inputTokens: Int(30_000 * scale), outputTokens: Int(3_000 * scale))))
            if day % 3 == 0 {
                buckets.append(UsageBucket(start: start, requests: 3, totals: UsageRecord(
                    source: .vision, model: "gpt-5.6-luna", purpose: "vision", inputTokens: 8_000, outputTokens: 600)))
            }
        }
        let snapshot = UsageDashboardSnapshot(range: range, interval: interval, current: buckets,
                                              previous: buckets.map { UsageBucket(start: $0.start, requests: $0.requests, totals: {
                                                  var t = $0.totals; t.inputTokens = t.inputTokens * 3 / 4; t.audioInputTokens = t.audioInputTokens * 3 / 4; return t }()) })
        let summary = snapshot.summary(filter: UsageFilter())

        for scheme in [ColorScheme.light, .dark] {
            let page = VStack(spacing: 16) {
                UsageHeroCard(summary: summary, range: range)
                UsageLiveSessionCard(meter: RealtimeUsageMeter(responses: 14, inputTokens: 18_000, outputTokens: 6_000,
                                                              inputAudioTokens: 14_000, outputAudioTokens: 5_000, cachedInputTokens: 0),
                                     model: "gpt-realtime-2.1-mini")
                UsageChartCard(summary: summary, range: range, interval: interval, metric: .constant(.spend))
                UsageBreakdownCard(title: "By model", symbol: "cpu", rows: summary.byModel, metric: .spend)
                UsageBreakdownCard(title: "By feature", symbol: "square.stack.3d.up", rows: summary.byFeature, metric: .tokens)
            }
            .padding(16)
            .frame(width: 393)
            .background(Color(.systemGroupedBackground))
            .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: page)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            let url = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-mac-Dedicatus-NeuraLink/5bcd1402-121e-471f-9672-1bf02b10568d/scratchpad/usage_\(scheme == .dark ? "dark" : "light").png")
            try image.pngData()!.write(to: url)
        }
    }
}
