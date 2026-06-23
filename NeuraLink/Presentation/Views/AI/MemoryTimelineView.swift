//
//  MemoryTimelineView.swift
//  NeuraLink
//
//  In-app timeline of recent voice turns, tool calls, and saved facts.
//

import SwiftUI

struct MemoryTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var memorySettings = MemorySettings.shared

    @State private var editFact: FactItem?
    @State private var showFactsInfo = false

    @State private var factsPage: Int = 0
    private let pageSize = 5

    @State private var totalFacts: Int = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Memory Enabled", isOn: Bindable(memorySettings).isEnabled)
                        .listRowSeparator(memorySettings.isEnabled ? .hidden : .automatic)

                    if memorySettings.isEnabled {
                        Picker("Auto-forget", selection: Bindable(memorySettings).autoForgetDays) {
                            Text("Never").tag(0)
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                        }
                        .listRowSeparator(.hidden)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Memory Quality")
                                Spacer()
                                Text(memorySettings.similarityFloor, format: .number.precision(.fractionLength(2)))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: Bindable(memorySettings).similarityFloor, in: 0.3...0.7, step: 0.05)
                            Text("Higher values surface fewer, more relevant memories.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Memory Controls")
                        Spacer()
                        Menu {
                            Button("Forget last 5 minutes", role: .destructive) { forgetLast(minutes: 5) }
                            Button("Forget last 15 minutes", role: .destructive) { forgetLast(minutes: 15) }
                            Button("Forget last 60 minutes", role: .destructive) { forgetLast(minutes: 60) }
                            Divider()
                            Button("Clear All (Unpinned)", role: .destructive) { forgetAllUnpinned() }
                        } label: {
                            Text("Forget")
                                .foregroundStyle(.red)
                        }
                        .tint(.red)
                        .disabled(!memorySettings.isEnabled)
                    }
                    .textCase(nil)
                } footer: {
                    Text("Memory is stored locally on-device (SQLite). Pinned items are not auto-deleted.")
                }

                Section {
                    factsPager
                } header: {
                    sectionHeader(
                        countLabel: factsCountLabel,
                        title: "Facts",
                        showInfo: $showFactsInfo,
                        infoText: "Important facts the assistant remembers about you (preferences, details, etc).",
                        onDeleteAll: deleteAllFacts
                    )
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { refreshCountsAndClampPages() }
            .onChange(of: memorySettings.autoForgetDays) { applyAutoForgetNow() }
            .onChange(of: factsPage) { refreshCountsAndClampPages() }
            .sheet(item: $editFact) { fact in
                FactEditSheet(fact: fact) { updated in
                    MemoryStore.shared.updateFact(
                        id: updated.id,
                        subject: updated.subject,
                        predicate: updated.predicate,
                        object: updated.object
                    )
                    refreshCountsAndClampPages()
                }
            }
        }
    }

    // MARK: - Pagers

    private let factsRowHeight: CGFloat = 52

    private var factsPager: some View {
        Group {
            if totalFacts == 0 {
                Text("No saved facts yet.")
                    .foregroundStyle(.secondary)
            } else {
                let itemCount = min(totalFacts, pageSize)
                TabView(selection: $factsPage) {
                    ForEach(0..<factsTotalPages, id: \.self) { page in
                        VStack(spacing: 0) {
                            let items = MemoryStore.shared.fetchAllFacts(
                                limit: pageSize,
                                offset: page * pageSize
                            )
                            ForEach(items) { f in
                                factsRow(f)
                                    .padding(.vertical, 8)
                                Divider()
                            }
                            Spacer(minLength: 0)
                        }
                        .tag(page)
                        .padding(.horizontal, 4)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: factsTotalPages > 1 ? .automatic : .never))
                .frame(height: factsRowHeight * CGFloat(itemCount) + (factsTotalPages > 1 ? 50 : 0))
            }
        }
    }

    // MARK: - Rows

    private func factsRow(_ f: FactItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(factDisplayText(f))
                        .font(.subheadline.weight(.medium))
                }
                Text(Self.timeFormatter.string(from: f.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                MemoryStore.shared.deleteFact(id: f.id)
                refreshCountsAndClampPages()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red.opacity(0.75))
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                editFact = f
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                MemoryStore.shared.deleteFact(id: f.id)
                refreshCountsAndClampPages()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Knowledge-graph entries have three fields; memory-table flat facts
    /// only fill `subject`. Join non-empty fields with single spaces so neither
    /// form renders extra whitespace.
    private func factDisplayText(_ f: FactItem) -> String {
        [f.subject, f.predicate, f.object]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Section header

    private func sectionHeader(
        countLabel: String,
        title: String,
        showInfo: Binding<Bool>,
        infoText: String,
        onDeleteAll: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 6) {
                Text(title)
                Button { showInfo.wrappedValue = true } label: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: showInfo) {
                    Text(infoText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                }
            }

            Spacer()

            Button(role: .destructive) { onDeleteAll() } label: {
                Text("Delete All")
            }
        }
        .textCase(nil)
    }

    // MARK: - Counts / paging

    private func refreshCountsAndClampPages() {
        totalFacts = MemoryStore.shared.countFacts()
        factsPage = min(max(factsPage, 0), max(factsTotalPages - 1, 0))
    }

    private var factsTotalPages: Int {
        max(1, Int(ceil(Double(totalFacts) / Double(pageSize))))
    }

    private var factsCountLabel: String {
        if totalFacts == 0 { return "0" }
        let shown = min((factsPage + 1) * pageSize, totalFacts)
        return "\(shown)/\(totalFacts)"
    }

    // MARK: - Actions

    private func applyAutoForgetNow() {
        let days = memorySettings.autoForgetDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400.0)
        MemoryStore.shared.pruneConversations(olderThan: cutoff)
        MemoryStore.shared.pruneMemories(olderThan: cutoff)
        refreshCountsAndClampPages()
    }

    private func forgetLast(minutes: Int) {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60.0)
        MemoryStore.shared.deleteConversations(since: cutoff)
        MemoryStore.shared.deleteMemories(since: cutoff, includePinned: false)
        factsPage = 0
        refreshCountsAndClampPages()
    }

    private func forgetAllUnpinned() {
        let veryOld = Date(timeIntervalSince1970: 0)
        MemoryStore.shared.deleteConversations(since: veryOld)
        MemoryStore.shared.deleteMemories(since: veryOld, includePinned: false)
        factsPage = 0
        refreshCountsAndClampPages()
    }

    private func deleteAllFacts() {
        MemoryStore.shared.deleteAllFacts()
        factsPage = 0
        refreshCountsAndClampPages()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct FactEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var subject: String
    @State private var predicate: String
    @State private var object: String

    let id: Int64
    let onSave: (FactItem) -> Void

    init(fact: FactItem, onSave: @escaping (FactItem) -> Void) {
        self.id = fact.id
        self.onSave = onSave
        _subject = State(initialValue: fact.subject)
        _predicate = State(initialValue: fact.predicate)
        _object = State(initialValue: fact.object)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Fact") {
                    TextField("Subject", text: $subject)
                    TextField("Predicate", text: $predicate)
                    TextField("Object", text: $object)
                }
            }
            .navigationTitle("Edit Fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let updated = FactItem(
                            id: id,
                            subject: subject,
                            predicate: predicate,
                            object: object,
                            timestamp: Date()
                        )
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || predicate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || object.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
