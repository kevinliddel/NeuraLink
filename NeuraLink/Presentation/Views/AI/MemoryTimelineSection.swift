//
//  MemoryTimelineSection.swift
//  NeuraLink
//
//  Dated facts on a month timeline with an "On this day" row
//  (docs/MEMORY_OWNERSHIP_PLAN.md §M3). Hidden until enough dated units exist.
//

import SwiftUI

struct MemoryTimelineSection: View {
    static let minimumDatedUnits = 5
    static let monthCount = 7

    @State private var months: [MemoryTimelineModel.Month] = []
    @State private var counts: [MemoryTimelineModel.Month: Int] = [:]
    @State private var selected: MemoryTimelineModel.Month?
    @State private var units: [MemoryUnit] = []
    @State private var onThisDay: [MemoryUnit] = []
    @State private var includeUndated = false
    @State private var isExpanded = false
    @State private var datedCount = 0

    var body: some View {
        if datedCount >= Self.minimumDatedUnits || !onThisDay.isEmpty {
            Section {
                if !onThisDay.isEmpty {
                    ForEach(onThisDay.prefix(3)) { unit in
                        row(unit, prefix: "On this day, \(Self.yearFormatter.string(from: unit.occurredStart ?? unit.mentionedAt)):")
                    }
                }
                DisclosureGroup(isExpanded: $isExpanded) {
                    monthStrip
                    if let selected {
                        let days = MemoryTimelineModel.daysInMonth(units, month: selected)
                        if days.isEmpty {
                            Text("Nothing dated in \(selected.label).").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(days, id: \.day) { group in
                            Text(Self.dayFormatter.string(from: group.day))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.units) { unit in row(unit, prefix: nil) }
                        }
                    }
                    Toggle("Include undated memories", isOn: $includeUndated)
                        .font(.caption)
                        .onChange(of: includeUndated) { _, _ in reload() }
                } label: {
                    InfoToggleLabel(
                        title: "Timeline",
                        info: "Memories placed on the day they happened. Tap a month to browse; things said without a date can be included by when they were mentioned.")
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text("When")
                }
                .textCase(nil)
            }
            .onAppear(perform: reload)
        } else {
            EmptyView().onAppear(perform: reload)
        }
    }

    private var monthStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(months) { month in
                    let count = counts[month] ?? 0
                    Button {
                        selected = month
                    } label: {
                        VStack(spacing: 2) {
                            Text(month.label).font(.caption.weight(.semibold))
                            Text(count == 0 ? "·" : "\(count)").font(.caption2).monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            selected == month ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                            in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func row(_ unit: MemoryUnit, prefix: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let url = PhotoMemoryService.thumbnailURL(for: unit), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: symbol(for: unit.factType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let prefix {
                    Text(prefix).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(unit.text).font(.subheadline)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                MemoryStore.shared.deleteUnit(id: unit.id)
                reload()
            } label: {
                Label("Forget", systemImage: "trash")
            }
        }
    }

    private func symbol(for type: MemoryFactType) -> String {
        switch type {
        case .observation: return "sparkles"
        case .raw: return "bubble.left"
        default: return "checkmark.seal"
        }
    }

    private func reload() {
        let now = Date()
        months = MemoryTimelineModel.recentMonths(count: Self.monthCount, now: now)
        if selected == nil { selected = months.last }
        let store = MemoryStore.shared
        datedCount = store.countDatedUnits()
        guard let first = months.first?.start, let last = months.last?.end else { return }
        units = store.fetchUnits(occurringBetween: first, and: last, includeUndated: includeUndated)
        counts = MemoryTimelineModel.countsByMonth(units, months: months)
        onThisDay = MemoryTimelineModel.onThisDay(store.fetchUnits(factTypes: MemoryFactType.knowledge), now: now)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f
    }()
}
