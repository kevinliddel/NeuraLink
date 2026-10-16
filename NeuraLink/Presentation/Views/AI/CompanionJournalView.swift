//
//  CompanionJournalView.swift
//  NeuraLink
//
//  The companion's journal — Living Companion (docs/LIVING_COMPANION.md).
//  Everything the character "remembers and becomes" is visible and
//  deletable here (trust + App Store safety): the relationship stage, a
//  calendar of the days you talked with the diary and keepsakes on them,
//  distilled personality traits, and a reset. Opened by tapping the
//  relationship meter capsule.
//
//  Created by Dedicatus on 08/09/2026. Calendar redesign 13/10/2026.
//

import SwiftUI

struct CompanionJournalView: View {
    let character: String

    @Environment(\.dismiss) private var dismiss
    @State private var companion = CompanionStateStore.shared
    @State private var month = JournalCalendarModel.month(containing: Date(), calendar: .current)
    @State private var selectedDay: Date?
    @State private var activity: [Date: JournalDayActivity] = [:]
    @State private var entries: [JournalEntry] = []
    @State private var milestones: [CompanionMilestone] = []
    @State private var conversations: [Int64: Conversation] = [:]
    @State private var traits: [PersonaTrait] = []
    @State private var portrait: UIImage?
    @State private var daysTogether = 0
    @State private var confirmReset = false

    private let calendar = Calendar.current

    private var displayName: String {
        character.isEmpty ? "Companion" : RealtimeChatState.displayName(for: character)
    }

    var body: some View {
        NavigationStack {
            List {
                relationshipSection
                calendarSection
                JournalDaySection(
                    selectedDay: selectedDay,
                    month: month,
                    activity: activity,
                    conversations: conversations,
                    calendar: calendar,
                    onClear: { withAnimation(.snappy) { selectedDay = nil } },
                    onOpenConversation: openTranscript,
                    onDelete: deleteEntry
                )
                CompanionKeepsakesSection(character: character)
                personalitySection
                resetSection
            }
            .listStyle(.insetGrouped)
            .scrollIndicators(.hidden)
            .navigationTitle("\(displayName)'s Journal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Reset \(displayName)'s personality?",
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button("Reset Personality", role: .destructive) { performReset() }
            } message: {
                Text("Deletes the diary and every learned personality note. Chat history, keepsakes and remembered facts are kept.")
            }
            .onAppear { reload() }
            .onChange(of: month) { _, _ in reloadMonth() }
        }
    }

    /// Transcripts open through ContentView's full-screen cover (the same
    /// path as the chat-history sidebar, with its Close / New Chat
    /// handlers). The journal is itself a sheet, so it dismisses first and
    /// hands over once that animation has had time to finish.
    private func openTranscript(_ conversationID: Int64) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            RealtimeChatState.shared.viewingConversationID = conversationID
        }
    }

    // MARK: - Sections

    private var relationshipSection: some View {
        Section {
            HStack(spacing: 12) {
                portraitView
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "suit.heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                        Text(companion.label)
                            .font(.subheadline.weight(.semibold))
                    }
                    ProgressView(value: companion.score)
                        .tint(.pink)
                    Text(daysTogether == 1 ? "1 day together" : "\(daysTogether) days together")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Relationship")
        }
    }

    /// Her face, from the live render when the widget pipeline has one,
    /// else the model's thumbnail; a heart when neither exists.
    @ViewBuilder
    private var portraitView: some View {
        if let portrait {
            Image(uiImage: portrait)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.pink.opacity(0.5), lineWidth: 1.5))
                .accessibilityLabel("\(displayName)'s portrait")
        } else {
            Image(systemName: "suit.heart.fill")
                .font(.title3)
                .foregroundStyle(.pink)
                .frame(width: 52, height: 52)
                .background(Color.pink.opacity(0.12), in: Circle())
        }
    }

    private var calendarSection: some View {
        Section {
            JournalCalendarView(
                month: $month,
                selectedDay: $selectedDay,
                activity: activity,
                calendar: calendar
            )
        } header: {
            Text("Together")
        } footer: {
            Text("Tap a day to see its conversations, diary and keepsakes. Swipe to change month.")
        }
    }

    private var personalitySection: some View {
        Section {
            if traits.isEmpty {
                Text("Nothing yet — personality notes appear as you talk together.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(traits) { trait in
                    Text(trait.trait)
                        .font(.subheadline)
                }
                .onDelete(perform: deleteTraits)
            }
        } header: {
            Text("Personality")
        } footer: {
            if !traits.isEmpty {
                Text("Learned from your conversations. Swipe to remove a note.")
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset Personality", role: .destructive) {
                confirmReset = true
            }
            .buttonStyle(.borderless)
            .disabled(entries.isEmpty && traits.isEmpty)
        }
    }

    // MARK: - Data

    private func reload() {
        companion.refresh()
        let store = MemoryStore.shared
        entries = store.journalEntries(character: character, limit: 2_000)
        milestones = store.milestones(character: character)
        traits = store.traits(character: character)
        conversations = Dictionary(uniqueKeysWithValues: store.fetchConversations().map { ($0.id, $0) })
        daysTogether = store.distinctUserMessageDays()
        portrait = CompanionPortrait.image(for: character)
        reloadMonth()
    }

    /// Turns are read per visible month (the only unbounded table); diary
    /// and keepsakes are already in memory.
    private func reloadMonth() {
        let turns = MemoryStore.shared.userTurnStamps(
            between: JournalCalendarModel.start(of: month, calendar: calendar),
            and: JournalCalendarModel.end(of: month, calendar: calendar))
        activity = JournalCalendarModel.activity(turns: turns, entries: entries, keepsakes: milestones, calendar: calendar)
    }

    private func deleteEntry(_ entry: JournalEntry) {
        CompanionSceneCapture.removeJournalFile(named: entry.snapshotFile)
        MemoryStore.shared.deleteJournalEntry(id: entry.id)
        reload()
    }

    private func deleteTraits(at offsets: IndexSet) {
        for index in offsets {
            MemoryStore.shared.deleteTrait(id: traits[index].id)
        }
        reload()
    }

    private func performReset() {
        for entry in entries { CompanionSceneCapture.removeJournalFile(named: entry.snapshotFile) }
        MemoryStore.shared.deleteJournal(character: character)
        MemoryStore.shared.deleteAllTraits(character: character)
        reload()
    }
}

#Preview {
    CompanionJournalView(character: "miku")
}
