//
//  UsageDashboardView.swift
//  NeuraLink
//
//  Dedicated OpenAI usage page (docs/API_USAGE.md), pushed from AI
//  Settings: range tabs, spend hero, live session,
//  source / model filters, the chart and per-model / per-feature
//  breakdowns. Everything is metered on this device from the `usage`
//  OpenAI returns with each call.
//
//  Created by Dedicatus on 30/09/2026.
//

import SwiftUI

struct UsageDashboardView: View {
    @State private var range: UsageRange = .week
    @State private var metric: UsageMetric = .spend
    @State private var filter = UsageFilter()
    @State private var snapshot = UsageDashboardSnapshot()
    @State private var confirmClear = false
    @State private var aiState = RealtimeChatState.shared

    private var summary: UsageSummary { snapshot.summary(filter: filter) }

    var body: some View {
        let summary = summary
        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                UsageHeroCard(summary: summary, range: range)

                if aiState.sessionUsage.responses > 0 {
                    UsageLiveSessionCard(meter: aiState.sessionUsage, model: OpenAISettings.shared.realtimeModel)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                UsageFilterBar(filter: $filter, models: summary.models)

                UsageChartCard(summary: summary, range: range, interval: snapshot.interval, metric: $metric)

                UsageBreakdownCard(
                    title: "By model", symbol: "cpu", rows: summary.byModel, metric: metric,
                    selectedID: filter.model.map { model in
                        summary.byModel.first { $0.totals.model == model }?.id ?? ""
                    },
                    onSelect: { row in
                        withAnimation(.snappy) {
                            filter.model = filter.model == row.totals.model ? nil : row.totals.model
                        }
                    })

                UsageBreakdownCard(
                    title: "By feature", symbol: "square.stack.3d.up", rows: summary.byFeature, metric: metric)

                footer
            }
            .padding(16)
            .animation(.snappy, value: aiState.sessionUsage.responses > 0)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Link(destination: Self.platformURL) {
                        Label("OpenAI usage dashboard", systemImage: "arrow.up.right.square")
                    }
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("Clear usage history", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Clear usage history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                MemoryStore.shared.deleteAllUsage()
                reload()
            }
        } message: {
            Text("Deletes the usage recorded on this device. Your OpenAI account and bill are not affected.")
        }
        .task(id: range) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: UsageRecorder.didChange)) { _ in reload() }
        .onChange(of: filter.source) { _, _ in
            // A model from another source would filter everything out.
            if let model = filter.model, !snapshot.summary(filter: filter).models.contains(model) {
                filter.model = nil
            }
        }
    }

    private static let platformURL = URL(string: "https://platform.openai.com/usage")!

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How this is measured", systemImage: "info.circle")
                .font(.footnote.weight(.semibold))
            Text("""
                Token counts are exactly what OpenAI reported for each call made from this device. \
                Spend is an estimate at list prices, without cached-input discounts; your OpenAI invoice is \
                the source of truth. Calls made with the same key elsewhere are not included.
                """)
            .font(.footnote)
            .foregroundStyle(.secondary)
            Link(destination: Self.platformURL) {
                Label("Open the OpenAI usage dashboard", systemImage: "arrow.up.right.square")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 4)
    }

    private func reload() {
        withAnimation(.snappy) {
            snapshot = UsageDashboardSnapshot.load(range: range)
        }
    }
}

/// Settings row into the dashboard — same circle-icon shape as the Models
/// row, with today's spend and tokens underneath.
struct UsageNavigationRow: View {
    @State private var today = UsageSummary()

    var body: some View {
        NavigationLink {
            UsageDashboardView()
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.teal.opacity(0.9), .indigo.opacity(0.75)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage")
                        .font(.headline)
                    Text(today.isEmpty
                         ? "No OpenAI calls today"
                         : "Today \(UsageFormat.cost(today.cost)) · \(UsageFormat.tokens(today.totals.totalTokens)) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UsageRecorder.didChange)) { _ in refresh() }
    }

    private func refresh() {
        today = UsageDashboardSnapshot.load(range: .today).summary(filter: UsageFilter())
    }
}
