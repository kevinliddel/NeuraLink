//
//  UsageDashboardModel.swift
//  NeuraLink
//
//  Pure aggregation behind the Usage dashboard (docs/API_USAGE.md): one
//  SQL read per range (current + previous window), then filtering, chart
//  series and breakdowns in memory — the bucket count is small.
//
//  Created by Dedicatus on 30/09/2026.
//

import Foundation

enum UsageRange: String, CaseIterable, Identifiable {
    case today, week, month, quarter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "7D"
        case .month: return "30D"
        case .quarter: return "90D"
        }
    }

    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    /// Today is charted per hour; longer ranges per day.
    var isHourly: Bool { self == .today }

    var periodLabel: String {
        switch self {
        case .today: return "today"
        default: return "last \(days) days"
        }
    }

    var comparisonLabel: String {
        self == .today ? "vs yesterday" : "vs previous \(days) days"
    }

    /// Whole local days ending with today.
    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? startOfToday
        return DateInterval(start: start, end: end)
    }

    /// The equally long window just before `interval(now:)`.
    func previousInterval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let current = interval(now: now, calendar: calendar)
        let start = calendar.date(byAdding: .day, value: -days, to: current.start) ?? current.start
        return DateInterval(start: start, end: current.start)
    }
}

enum UsageMetric: String, CaseIterable, Identifiable {
    case spend, tokens

    var id: String { rawValue }
    var title: String { self == .spend ? "Spend" : "Tokens" }

    func value(of record: UsageRecord) -> Double {
        self == .spend ? record.estimatedCost : Double(record.totalTokens)
    }

    func format(_ value: Double) -> String {
        self == .spend ? UsageFormat.cost(value) : UsageFormat.tokens(Int(value))
    }
}

struct UsageFilter: Equatable {
    var source: UsageSource?
    var model: String?

    func matches(_ bucket: UsageBucket) -> Bool {
        (source == nil || bucket.totals.source == source)
            && (model == nil || bucket.totals.model == model)
    }
}

/// One bar segment: a source's total in one hour/day.
struct UsageChartPoint: Identifiable, Equatable {
    let start: Date
    let source: UsageSource
    let totals: UsageRecord

    var id: String { "\(start.timeIntervalSince1970)|\(source.rawValue)" }
}

/// One line of a "by model" / "by feature" breakdown.
struct UsageBreakdownRow: Identifiable, Equatable {
    let id: String
    let title: String
    let source: UsageSource
    let requests: Int
    let totals: UsageRecord
}

struct UsageSummary: Equatable {
    var totals = UsageRecord(source: .text, model: "")
    var requests = 0
    var cost: Double = 0
    var previousCost: Double = 0
    var previousTokens = 0
    var points: [UsageChartPoint] = []
    var byModel: [UsageBreakdownRow] = []
    var byFeature: [UsageBreakdownRow] = []
    /// Sources present in the window, heaviest first (legend order).
    var sources: [UsageSource] = []
    /// Models present for the active source filter (model picker items).
    var models: [String] = []

    var isEmpty: Bool { requests == 0 }

    /// Fractional change vs the previous window; nil when there is nothing
    /// to compare against.
    func change(for metric: UsageMetric) -> Double? {
        let now = metric == .spend ? cost : Double(totals.totalTokens)
        let before = metric == .spend ? previousCost : Double(previousTokens)
        guard before > 0 else { return nil }
        return (now - before) / before
    }
}

struct UsageDashboardSnapshot {
    var range: UsageRange = .week
    var interval = DateInterval()
    var current: [UsageBucket] = []
    var previous: [UsageBucket] = []

    static func load(range: UsageRange, now: Date = Date(), store: MemoryStore = .shared) -> UsageDashboardSnapshot {
        let interval = range.interval(now: now)
        let previousInterval = range.previousInterval(now: now)
        return UsageDashboardSnapshot(
            range: range,
            interval: interval,
            current: store.usageBuckets(from: interval.start, to: interval.end, hourly: range.isHourly),
            previous: store.usageBuckets(from: previousInterval.start, to: previousInterval.end, hourly: false))
    }

    func summary(filter: UsageFilter) -> UsageSummary {
        var summary = UsageSummary()
        let rows = current.filter(filter.matches)

        var points: [String: UsageChartPoint] = [:]
        var models: [String: UsageBreakdownRow] = [:]
        var features: [String: UsageBreakdownRow] = [:]
        var sourceCost: [UsageSource: Double] = [:]

        for bucket in rows {
            summary.totals.add(bucket.totals)
            summary.requests += bucket.requests
            summary.cost += bucket.totals.estimatedCost
            sourceCost[bucket.totals.source, default: 0] += bucket.totals.estimatedCost

            let point = UsageChartPoint(start: bucket.start, source: bucket.totals.source, totals: bucket.totals)
            points[point.id] = points[point.id].map { merged($0, with: bucket.totals) } ?? point

            let modelKey = "\(bucket.totals.source.rawValue)|\(bucket.totals.model)"
            models[modelKey] = accumulate(
                models[modelKey], id: modelKey, title: bucket.totals.model, bucket: bucket)

            let feature = UsageFormat.featureTitle(bucket.totals.purpose, source: bucket.totals.source)
            features[feature] = accumulate(features[feature], id: feature, title: feature, bucket: bucket)
        }

        for bucket in previous where filter.matches(bucket) {
            summary.previousCost += bucket.totals.estimatedCost
            summary.previousTokens += bucket.totals.totalTokens
        }

        summary.points = points.values.sorted { ($0.start, $0.source.rawValue) < ($1.start, $1.source.rawValue) }
        summary.byModel = Self.ranked(models.values)
        summary.byFeature = Self.ranked(features.values)
        summary.sources = sourceCost.sorted { $0.value > $1.value }.map(\.key)

        var modelCost: [String: Double] = [:]
        for bucket in current where filter.source == nil || bucket.totals.source == filter.source {
            modelCost[bucket.totals.model, default: 0] += bucket.totals.estimatedCost
        }
        summary.models = modelCost.sorted { $0.value > $1.value }.map(\.key)
        return summary
    }

    /// Bucket totals per source for one chart column (tooltip content).
    func column(at start: Date, in summary: UsageSummary) -> [UsageChartPoint] {
        summary.points.filter { $0.start == start }
    }

    private func merged(_ point: UsageChartPoint, with record: UsageRecord) -> UsageChartPoint {
        var totals = point.totals
        totals.add(record)
        return UsageChartPoint(start: point.start, source: point.source, totals: totals)
    }

    private func accumulate(_ row: UsageBreakdownRow?, id: String, title: String, bucket: UsageBucket) -> UsageBreakdownRow {
        var totals = row?.totals ?? UsageRecord(source: bucket.totals.source, model: bucket.totals.model)
        totals.add(bucket.totals)
        return UsageBreakdownRow(
            id: id, title: title, source: bucket.totals.source,
            requests: (row?.requests ?? 0) + bucket.requests, totals: totals)
    }

    private static func ranked(_ rows: Dictionary<String, UsageBreakdownRow>.Values) -> [UsageBreakdownRow] {
        rows.sorted {
            ($0.totals.estimatedCost, $0.totals.totalTokens) > ($1.totals.estimatedCost, $1.totals.totalTokens)
        }
    }
}

enum UsageFormat {
    static func cost(_ value: Double) -> String {
        if value <= 0 { return "$0.00" }
        if value < 0.01 { return "<$0.01" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func tokens(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return String(format: "%.1fk", Double(value) / 1_000)
        default: return String(format: "%.2fM", Double(value) / 1_000_000)
        }
    }

    static func featureTitle(_ purpose: String, source: UsageSource) -> String {
        switch purpose {
        case "conversation": return "Voice conversation"
        case "transcription": return "Speech to text"
        case "reflection": return "Reflections"
        case "title": return "Chat titles"
        case "memory": return "Memory"
        case "vision": return "Camera vision"
        default: return source == .text ? "Other background" : source.title
        }
    }
}
