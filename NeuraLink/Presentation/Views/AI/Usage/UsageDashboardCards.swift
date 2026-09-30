//
//  UsageDashboardCards.swift
//  NeuraLink
//
//  Building blocks of the Usage dashboard (docs/API_USAGE.md): hero
//  spend card, filter bar, the interactive chart, and breakdown lists.
//
//  Created by Dedicatus on 30/09/2026.
//

import Charts
import SwiftUI

extension UsageSource {
    var tint: Color {
        switch self {
        case .voice: return Color(red: 0.49, green: 0.23, blue: 0.93)
        case .transcription: return Color(red: 0.08, green: 0.66, blue: 0.62)
        case .text: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .vision: return Color(red: 0.96, green: 0.62, blue: 0.04)
        }
    }
}

/// Rounded surface every dashboard section sits on.
struct UsageCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Hero

struct UsageHeroCard: View {
    let summary: UsageSummary
    let range: UsageRange

    private var average: (value: String, label: String) {
        if range.isHourly {
            let hours = max(1, Calendar.current.component(.hour, from: Date()) + 1)
            return (UsageFormat.cost(summary.cost / Double(hours)), "Per hour")
        }
        return (UsageFormat.cost(summary.cost / Double(range.days)), "Daily avg")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ESTIMATED SPEND · \(range.periodLabel.uppercased())")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(UsageFormat.cost(summary.cost))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                changeChip
            }

            HStack(spacing: 10) {
                UsageStatTile(value: UsageFormat.tokens(summary.totals.totalTokens), label: "Tokens", symbol: "number")
                UsageStatTile(value: "\(summary.requests)", label: "Requests", symbol: "arrow.left.arrow.right")
                UsageStatTile(value: average.value, label: average.label, symbol: "calendar")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.55, blue: 0.62), Color(red: 0.25, green: 0.30, blue: 0.85),
                         Color(red: 0.49, green: 0.23, blue: 0.93)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .indigo.opacity(0.25), radius: 14, y: 6)
        .animation(.snappy, value: summary.cost)
    }

    @ViewBuilder private var changeChip: some View {
        if let change = summary.change(for: .spend) {
            let up = change >= 0
            HStack(spacing: 4) {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                Text("\(abs(change).formatted(.percent.precision(.fractionLength(0)))) \(range.comparisonLabel)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.18), in: Capsule())
        } else {
            Text(summary.isEmpty ? "No calls \(range.periodLabel)" : "Nothing to compare \(range.comparisonLabel)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

struct UsageStatTile: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Filters

struct UsageFilterBar: View {
    @Binding var filter: UsageFilter
    let models: [String]

    var body: some View {
        UsageCard {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip(title: "All", symbol: "square.grid.2x2", tint: .primary, isOn: filter.source == nil) {
                        filter.source = nil
                    }
                    ForEach(UsageSource.allCases) { source in
                        chip(title: source.title, symbol: source.symbol, tint: source.tint, isOn: filter.source == source) {
                            filter.source = filter.source == source ? nil : source
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                DropDownSelector(
                    items: [""] + models,
                    selection: Binding(get: { filter.model ?? "" }, set: { filter.model = $0.isEmpty ? nil : $0 }),
                    title: { $0.isEmpty ? "All models" : $0 })
                    .frame(height: 44)
            }
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func chip(title: String, symbol: String, tint: Color, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isOn ? Color.white : tint)
                .background(isOn ? AnyShapeStyle(tint == .primary ? Color.accentColor : tint) : AnyShapeStyle(tint.opacity(0.12)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Breakdown

struct UsageBreakdownCard: View {
    let title: String
    let symbol: String
    let rows: [UsageBreakdownRow]
    let metric: UsageMetric
    var selectedID: String?
    var onSelect: ((UsageBreakdownRow) -> Void)?

    private var maxValue: Double {
        rows.map { metric.value(of: $0.totals) }.max() ?? 0
    }

    var body: some View {
        UsageCard {
            Label(title, systemImage: symbol)
                .font(.headline)
            if rows.isEmpty {
                Text("Nothing in this range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                if let onSelect {
                    Button(action: { onSelect(row) }, label: { rowView(row) })
                        .buttonStyle(.plain)
                } else {
                    rowView(row)
                }
            }
        }
    }

    private func rowView(_ row: UsageBreakdownRow) -> some View {
        let value = metric.value(of: row.totals)
        let share = maxValue > 0 ? value / maxValue : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(row.source.tint).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(row.source.title) · \(row.requests) calls · in \(UsageFormat.tokens(row.totals.inputTokens)) / out \(UsageFormat.tokens(row.totals.outputTokens))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(metric.format(value))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(metric == .spend ? UsageFormat.tokens(row.totals.totalTokens) + " tok" : UsageFormat.cost(row.totals.estimatedCost))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if row.id == selectedID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(row.source.tint)
                }
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(row.source.tint.gradient)
                    .frame(width: max(4, proxy.size.width * share))
            }
            .frame(height: 5)
            .animation(.snappy, value: share)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

// MARK: - Live session

struct UsageLiveSessionCard: View {
    let meter: RealtimeUsageMeter
    let model: String

    @State private var pulse = false

    private var record: UsageRecord {
        var record = UsageRecord(source: .voice, model: model)
        record.inputTokens = meter.inputTokens
        record.outputTokens = meter.outputTokens
        record.audioInputTokens = meter.inputAudioTokens
        record.audioOutputTokens = meter.outputAudioTokens
        return record
    }

    var body: some View {
        UsageCard {
            HStack(spacing: 12) {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .opacity(pulse ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live voice session")
                        .font(.subheadline.weight(.semibold))
                    Text("\(meter.responses) responses · \(model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageFormat.cost(record.estimatedCost))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("\(UsageFormat.tokens(meter.totalTokens)) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .onAppear { pulse = true }
    }
}
