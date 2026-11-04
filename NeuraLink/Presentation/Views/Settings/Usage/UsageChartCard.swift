//
//  UsageChartCard.swift
//  NeuraLink
//
//  Stacked bar chart of spend or tokens per hour (Today) or per day, one
//  colour per source. Drag across the bars to inspect a column
//  (docs/API_USAGE.md).
//
//  Created by Dedicatus on 30/09/2026.
//

import Charts
import SwiftUI

struct UsageChartCard: View {
    let summary: UsageSummary
    let range: UsageRange
    let interval: DateInterval
    @Binding var metric: UsageMetric

    @State private var rawSelection: Date?

    private var unit: Calendar.Component { range.isHourly ? .hour : .day }

    /// The bucket under the finger, snapped to its hour/day start.
    private var selectedStart: Date? {
        guard let rawSelection else { return nil }
        return Calendar.current.dateInterval(of: unit, for: rawSelection)?.start
    }

    private var selectedColumn: [UsageChartPoint] {
        guard let selectedStart else { return [] }
        return summary.points.filter { $0.start == selectedStart }
    }

    private var peak: (start: Date, value: Double)? {
        var totals: [Date: Double] = [:]
        for point in summary.points { totals[point.start, default: 0] += metric.value(of: point.totals) }
        return totals.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    var body: some View {
        UsageCard {
            HStack {
                Text(metric == .spend ? "Spend" : "Tokens")
                    .font(.headline)
                Spacer()
                Picker("Metric", selection: $metric.animation(.snappy)) {
                    ForEach(UsageMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            header
                .frame(height: 38, alignment: .topLeading)

            chart
                .frame(height: 220)
                .overlay {
                    if summary.isEmpty {
                        ContentUnavailableView(
                            "No usage yet", systemImage: "chart.bar",
                            description: Text("OpenAI calls show up here as you chat."))
                    }
                }

            legend
        }
        .sensoryFeedback(.selection, trigger: selectedStart)
    }

    // MARK: - Header (selection readout / peak)

    @ViewBuilder private var header: some View {
        if let selectedStart, !selectedColumn.isEmpty {
            let total = selectedColumn.reduce(0) { $0 + metric.value(of: $1.totals) }
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.format(total))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                HStack(spacing: 8) {
                    Text(label(for: selectedStart))
                    ForEach(selectedColumn) { point in
                        HStack(spacing: 3) {
                            Circle().fill(point.source.tint).frame(width: 6, height: 6)
                            Text(metric.format(metric.value(of: point.totals)))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else if let peak, peak.value > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("Peak \(metric.format(peak.value))")
                    .font(.subheadline.weight(.semibold))
                Text("\(label(for: peak.start)) · drag across the bars for details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(for date: Date) -> String {
        range.isHourly
            ? date.formatted(.dateTime.hour())
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(summary.points) { point in
                BarMark(
                    x: .value("Time", point.start, unit: unit),
                    y: .value(metric.title, metric.value(of: point.totals)))
                .foregroundStyle(by: .value("Source", point.source.title))
                .cornerRadius(3)
                .opacity(selectedStart == nil || selectedStart == point.start ? 1 : 0.35)
            }
            if let selectedStart {
                RuleMark(x: .value("Selected", selectedStart, unit: unit))
                    .foregroundStyle(Color.secondary.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: range == .quarter ? 4 : 14))
                    .zIndex(-1)
            }
        }
        .chartForegroundStyleScale(
            domain: UsageSource.allCases.map(\.title),
            range: UsageSource.allCases.map(\.tint))
        .chartLegend(.hidden)
        .chartXScale(domain: interval.start...interval.end)
        .chartXSelection(value: $rawSelection)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric.format(number))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: unit, count: xStride)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: xFormat, centered: true)
            }
        }
        .animation(.snappy, value: summary.points)
    }

    private var xStride: Int {
        switch range {
        case .today: return 6
        case .week: return 1
        case .month: return 7
        case .quarter: return 21
        }
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .today: return .dateTime.hour()
        case .week: return .dateTime.weekday(.narrow)
        case .month, .quarter: return .dateTime.day().month(.abbreviated)
        }
    }

    // MARK: - Legend (present sources only, with totals)

    @ViewBuilder private var legend: some View {
        if !summary.sources.isEmpty {
            HStack(spacing: 14) {
                ForEach(summary.sources) { source in
                    let value = summary.points
                        .filter { $0.source == source }
                        .reduce(0) { $0 + metric.value(of: $1.totals) }
                    HStack(spacing: 5) {
                        Circle().fill(source.tint).frame(width: 8, height: 8)
                        Text(source.title).foregroundStyle(.secondary)
                        Text(metric.format(value)).fontWeight(.semibold).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }
}
