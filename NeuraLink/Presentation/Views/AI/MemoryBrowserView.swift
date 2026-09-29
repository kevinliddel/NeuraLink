//
//  MemoryBrowserView.swift
//  NeuraLink
//
//  The full list behind "Show all" on Insights and Facts.
//
//  Collapsing a few rows inline works at a dozen entries and stops working
//  at a hundred: the settings below scroll away, there is no way to find one
//  entry, and deleting means hunting. This is a screen of its own — grouped
//  by when the companion learned each thing, searchable, and laid out as
//  cards so a long memory reads as a record rather than a dump.
//

import SwiftUI

/// One entry, flattened out of whatever the caller stores.
struct MemoryBrowserItem: Identifiable {
    let id: String
    let text: String
    let date: Date
    /// Short trailing note — a source count, say. Optional.
    let detail: String?
    let detailSymbol: String?
}

struct MemoryBrowserView: View {
    let title: String
    let symbol: String
    let tint: Color
    let items: [MemoryBrowserItem]
    var onDelete: (MemoryBrowserItem) -> Void
    /// Absent where there is nothing to edit — insights are derived, not written.
    var onEdit: ((MemoryBrowserItem) -> Void)?

    @State private var query = ""

    var body: some View {
        List {
            if matches.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.items) { item in
                            card(item)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { onDelete(item) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    if let onEdit {
                                        Button { onEdit(item) } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.blue)
                                    }
                                }
                        }
                    } header: {
                        header(group)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $query, prompt: "Search \(title.lowercased())")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // The count belongs where it doesn't compete with the rows,
                // and it tracks the filter so a search says what it found.
                Text(query.isEmpty ? "\(items.count)" : "\(matches.count)/\(items.count)")
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pieces

    private func card(_ item: MemoryBrowserItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let detail = item.detail {
                        Label(detail, systemImage: item.detailSymbol ?? "link")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(tint)
                    }
                    Text(Self.timeFormatter.string(from: item.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tint.opacity(0.16), lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { onEdit?(item) }
    }

    private func header(_ group: Group) -> some View {
        HStack(spacing: 6) {
            Text(group.title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(group.items.count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tint.opacity(0.14), in: Capsule())
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? symbol : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(tint.opacity(0.7))
            Text(query.isEmpty ? "Nothing here yet" : "No matches")
                .font(.subheadline.weight(.medium))
            Text(query.isEmpty
                ? "This is where they'll appear."
                : "Nothing matches “\(query)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Grouping

    private struct Group {
        let title: String
        let items: [MemoryBrowserItem]
    }

    private var matches: [MemoryBrowserItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Newest first, bucketed by when it was learned — hundreds of rows in
    /// one run give no sense of what is recent and what is old.
    private var groups: [Group] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(order: Int, title: String, items: [MemoryBrowserItem])] = []
        for item in matches.sorted(by: { $0.date > $1.date }) {
            let order: Int
            let title: String
            if calendar.isDateInToday(item.date) {
                (order, title) = (0, "Today")
            } else if calendar.isDateInYesterday(item.date) {
                (order, title) = (1, "Yesterday")
            } else if let days = calendar.dateComponents([.day], from: item.date, to: now).day,
                days < 7 {
                (order, title) = (2, "This week")
            } else if calendar.isDate(item.date, equalTo: now, toGranularity: .month) {
                (order, title) = (3, "This month")
            } else {
                (order, title) = (4, "Earlier")
            }
            if let index = buckets.firstIndex(where: { $0.order == order }) {
                buckets[index].items.append(item)
            } else {
                buckets.append((order, title, [item]))
            }
        }
        return buckets.sorted { $0.order < $1.order }.map { Group(title: $0.title, items: $0.items) }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
