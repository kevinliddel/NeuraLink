//
//  MemoryTimelineView.swift
//  NeuraLink
//
//  The Memory page: what the companion knows (hero card), memory
//  controls, consolidated insights, saved facts, and privacy actions.
//  Data comes from the agentic memory layer (docs/AGENTIC_MEMORY.md).
//

import SwiftUI

struct MemoryTimelineView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var memorySettings = MemorySettings.shared

    @State private var snapshot = MemoryPageSnapshot()
    @State private var facts: [FactItem] = []
    @State private var showAllFacts = false
    @State private var showAllObservations = false
    @State private var isRefreshing = false
    @State private var editFact: FactItem?
    @State private var confirmClearAll = false
    @State private var showExport = false
    @State private var recap: MentalModel?

    private let collapsedLimit = 5

    private var characterName: String {
        let name = RealtimeChatState.shared.selectedCharacterName
        return name.isEmpty ? "Your companion" : name.capitalized
    }

    var body: some View {
        NavigationStack {
            List {
                recapSection
                heroSection
                MemoryTimelineSection()
                controlsSection
                observationsSection
                factsSection
                privacySection
            }
            .listStyle(.insetGrouped)
            .scrollIndicators(.hidden)
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .onChange(of: memorySettings.autoForgetDays) { applyAutoForgetNow() }
            .sheet(isPresented: $showExport) { MemoryExportSheet() }
            .sheet(item: $editFact) { fact in
                FactEditSheet(fact: fact) { updated in
                    MemoryStore.shared.updateFact(
                        id: updated.id, subject: updated.subject,
                        predicate: updated.predicate, object: updated.object)
                    reload()
                }
            }
            .confirmationDialog(
                "Clear all memories?", isPresented: $confirmClearAll, titleVisibility: .visible
            ) {
                Button("Clear everything except pinned", role: .destructive) { forgetAllUnpinned() }
            } message: {
                Text("Conversations, facts and insights are removed from this device. Pinned items stay.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var recapSection: some View {
        if let recap, !recap.content.isEmpty, !MemoryRecapCard.Dismissal.isDismissed() {
            Section {
                MemoryRecapCard(
                    characterName: characterName, content: recap.content,
                    onAsk: {
                        MemoryMentalModels.shared.askAboutRecap(character: RealtimeChatState.shared.selectedCharacterName)
                        dismiss()
                    },
                    onDismiss: {
                        MemoryRecapCard.Dismissal.dismiss()
                        self.recap = nil
                    })
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    private var heroSection: some View {
        Section {
            MemoryHeroCard(
                characterName: characterName, snapshot: snapshot,
                isEnabled: memorySettings.isEnabled, isRefreshing: isRefreshing, onRefresh: refreshNow)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var controlsSection: some View {
        Section {
            Toggle(isOn: Bindable(memorySettings).isEnabled) {
                Label {
                    InfoToggleLabel(
                        title: "Remember conversations",
                        info: "Facts, insights and moments from your chats are kept on this device only, so \(characterName) can bring them up later.")
                } icon: {
                    settingIcon("brain", color: .purple)
                }
            }

            if memorySettings.isEnabled {
                HStack {
                    Label("Auto-forget", systemImage: "clock.arrow.circlepath")
                        .labelStyle(SettingLabelStyle(color: .orange))
                    Spacer()
                    DropDownSelector(items: [0, 7, 14, 30], selection: Bindable(memorySettings).autoForgetDays) { days in
                        days == 0 ? "Never" : "After \(days) days"
                    }
                }

                MemoryEmbeddingModelRow()

                Toggle(isOn: Bindable(memorySettings).charactersShareMemories) {
                    Label {
                        InfoToggleLabel(
                            title: "Characters share memories",
                            info: "On: every character can recall everything. Off: each character only recalls what it experienced itself, plus the facts about you, which are always shared.")
                    } icon: {
                        settingIcon("person.2", color: .indigo)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label {
                            InfoToggleLabel(
                                title: "Recall precision",
                                info: "How closely a memory must match what you're talking about before it is brought up. Only affects meaning-based matching; names, places and dates are always matched exactly.")
                        } icon: {
                            settingIcon("scope", color: .blue)
                        }
                        Spacer()
                        Text(precisionLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Bindable(memorySettings).similarityFloor, in: 0.3...0.7, step: 0.05)
                    HStack {
                        Text("Broader").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("Stricter").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Controls")
        }
    }

    private var observationsSection: some View {
        Section {
            if snapshot.observationUnits.isEmpty {
                MemoryEmptyRow(
                    symbol: "sparkles", title: "No insights yet",
                    detail: "\(characterName) distils repeated facts into insights in the background.")
            } else {
                ForEach(visibleObservations) { unit in
                    MemoryObservationRow(unit: unit)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { deleteObservation(unit) } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                }
                if snapshot.observationUnits.count > collapsedLimit {
                    showMoreButton(isExpanded: $showAllObservations, total: snapshot.observationUnits.count)
                }
            }
        } header: {
            sectionHeader(
                "Insights", count: snapshot.observationUnits.count, symbol: "sparkles",
                info: "Beliefs \(characterName) distilled from facts that came up more than once. Swipe one to forget it; the summary above is rebuilt from these.")
        }
    }

    private var factsSection: some View {
        Section {
            if facts.isEmpty {
                MemoryEmptyRow(
                    symbol: "checkmark.seal", title: "No saved facts",
                    detail: "Tell \(characterName) about yourself and it will note the details here.")
            } else {
                ForEach(visibleFacts) { fact in
                    factRow(fact)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { deleteFact(fact) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editFact = fact } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
                if facts.count > collapsedLimit {
                    showMoreButton(isExpanded: $showAllFacts, total: facts.count)
                }
            }
        } header: {
            HStack {
                sectionHeader(
                    "Facts", count: facts.count, symbol: "checkmark.seal",
                    info: "Details you told \(characterName) about yourself. Tap a fact to edit it, swipe to delete.")
                Spacer()
                if !facts.isEmpty {
                    Button("Delete all", role: .destructive) { deleteAllFacts() }
                        .font(.caption)
                }
            }
        }
    }

    private var privacySection: some View {
        Section {
            Menu {
                Button("Last 5 minutes", role: .destructive) { forgetLast(minutes: 5) }
                Button("Last 15 minutes", role: .destructive) { forgetLast(minutes: 15) }
                Button("Last hour", role: .destructive) { forgetLast(minutes: 60) }
            } label: {
                Label("Forget recent…", systemImage: "eraser")
                    .labelStyle(SettingLabelStyle(color: .red))
            }
            .disabled(!memorySettings.isEnabled)

            Button { showExport = true } label: {
                Label {
                    InfoToggleLabel(
                        title: "Export memory…",
                        info: "Saves everything the companion remembers as a JSON file you can keep, share or inspect. Nothing leaves the device unless you share it.")
                } icon: {
                    settingIcon("square.and.arrow.up", color: .blue)
                }
            }
            .disabled(!memorySettings.isEnabled)

            Button(role: .destructive) { confirmClearAll = true } label: {
                Label {
                    InfoToggleLabel(
                        title: "Clear all memories",
                        info: "Removes conversations, facts and insights from this device. Pinned items stay. Nothing is ever uploaded for storage; only what's relevant to a conversation is shared with the AI you're talking to.")
                } icon: {
                    settingIcon("trash", color: .red)
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Stored on this device only.")
        }
    }

    // MARK: - Rows & helpers

    private func factRow(_ fact: FactItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(factDisplayText(fact))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.timeFormatter.string(from: fact.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { editFact = fact }
    }

    private func sectionHeader(_ title: String, count: Int, symbol: String, info: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            InfoToggleLabel(title: title, info: info)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .textCase(nil)
    }

    private func showMoreButton(isExpanded: Binding<Bool>, total: Int) -> some View {
        Button {
            withAnimation(.snappy) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack {
                Spacer()
                Text(isExpanded.wrappedValue ? "Show fewer" : "Show all \(total)")
                    .font(.subheadline.weight(.medium))
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
        }
        .buttonStyle(.borderless)
    }

    private func settingIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var visibleObservations: [MemoryUnit] {
        showAllObservations ? snapshot.observationUnits : Array(snapshot.observationUnits.prefix(collapsedLimit))
    }

    private var visibleFacts: [FactItem] {
        showAllFacts ? facts : Array(facts.prefix(collapsedLimit))
    }

    private var precisionLabel: String {
        switch memorySettings.similarityFloor {
        case ..<0.4: return "Broad"
        case ..<0.55: return "Balanced"
        default: return "Strict"
        }
    }

    /// Knowledge-graph entries have three fields; flat facts only fill
    /// `subject`. Join the non-empty fields with single spaces.
    private func factDisplayText(_ f: FactItem) -> String {
        [f.subject, f.predicate.replacingOccurrences(of: "_", with: " "), f.object]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Data

    private func reload() {
        let character = RealtimeChatState.shared.selectedCharacterName
        // Small indexed queries; the previous page ran them inline in `body`.
        Task {
            let loaded = MemoryPageSnapshot.load(character: character)
            let loadedFacts = MemoryStore.shared.fetchAllFacts()
            let loadedRecap = MemoryStore.shared.fetchMentalModel(character: character, slug: MemoryMentalModels.weeklyRecapSlug)
            withAnimation(.snappy) {
                snapshot = loaded
                facts = loadedFacts
                recap = loadedRecap
            }
        }
    }

    /// Flushes pending turns, consolidates, and rebuilds the summaries.
    private func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let character = RealtimeChatState.shared.selectedCharacterName
        Task.detached(priority: .userInitiated) {
            await MemoryConsolidator.shared.consolidatePending()
            await MemoryStore.shared.markMentalModelsStale()
            await MemoryMentalModels.shared.refreshStale(character: character)
            await MainActor.run {
                isRefreshing = false
                reload()
            }
        }
    }

    // MARK: - Actions

    private func deleteObservation(_ unit: MemoryUnit) {
        MemoryStore.shared.deleteUnit(id: unit.id)
        MemoryStore.shared.markMentalModelsStale()
        reload()
    }

    private func deleteFact(_ fact: FactItem) {
        MemoryStore.shared.deleteFact(id: fact.id)
        reload()
    }

    private func deleteAllFacts() {
        MemoryStore.shared.deleteAllFacts()
        reload()
    }

    private func applyAutoForgetNow() {
        let days = memorySettings.autoForgetDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400.0)
        MemoryStore.shared.pruneConversations(olderThan: cutoff)
        MemoryStore.shared.pruneMemories(olderThan: cutoff)
        reload()
    }

    private func forgetLast(minutes: Int) {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60.0)
        MemoryStore.shared.deleteConversations(since: cutoff)
        MemoryStore.shared.deleteMemories(since: cutoff, includePinned: false)
        MemoryStore.shared.markMentalModelsStale()
        reload()
    }

    private func forgetAllUnpinned() {
        let veryOld = Date(timeIntervalSince1970: 0)
        MemoryStore.shared.deleteConversations(since: veryOld)
        MemoryStore.shared.deleteMemories(since: veryOld, includePinned: false)
        MemoryStore.shared.markMentalModelsStale()
        reload()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Coloured rounded icon tile in front of a settings label, matching the
/// iOS Settings look.
struct SettingLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            configuration.title
        }
    }
}
