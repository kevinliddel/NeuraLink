//
//  CompanionJournalView.swift
//  NeuraLink
//
//  The companion's journal — Living Companion Phase 2
//  (docs/LIVING_COMPANION_PLAN.md §⑤). Everything the character "remembers
//  and becomes" is visible and deletable here (trust + App Store safety):
//  the relationship stage, distilled personality traits, and the diary the
//  reflection pipeline writes after each session. Opened by tapping the
//  relationship meter capsule.
//
//  Created by Dedicatus on 08/09/2026.
//

import SwiftUI

struct CompanionJournalView: View {
    let character: String

    @Environment(\.dismiss) private var dismiss
    @State private var companion = CompanionStateStore.shared
    @State private var entries: [JournalEntry] = []
    @State private var traits: [PersonaTrait] = []
    @State private var confirmReset = false

    private var displayName: String {
        character.isEmpty ? "Companion" : character.capitalized
    }

    var body: some View {
        NavigationStack {
            Form {
                relationshipSection
                personalitySection
                journalSection
                resetSection
            }
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
                Text("Deletes the diary and every learned personality note. Chat history and remembered facts are kept.")
            }
            .onAppear { reload() }
        }
    }

    // MARK: - Sections

    private var relationshipSection: some View {
        Section("Relationship") {
            HStack(spacing: 10) {
                Image(systemName: "suit.heart.fill")
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 4) {
                    Text(companion.label)
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: companion.score)
                        .tint(.pink)
                }
            }
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

    private var journalSection: some View {
        Section {
            if entries.isEmpty {
                Text("No reflections yet — finish a conversation with Companion Presence enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.createdAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(entry.diary)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete(perform: deleteEntries)
            }
        } header: {
            Text("Diary")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset Personality", role: .destructive) {
                confirmReset = true
            }
            .disabled(entries.isEmpty && traits.isEmpty)
        }
    }

    // MARK: - Data

    private func reload() {
        companion.refresh()
        entries = MemoryStore.shared.journalEntries(character: character)
        traits = MemoryStore.shared.traits(character: character)
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            MemoryStore.shared.deleteJournalEntry(id: entries[index].id)
        }
        reload()
    }

    private func deleteTraits(at offsets: IndexSet) {
        for index in offsets {
            MemoryStore.shared.deleteTrait(id: traits[index].id)
        }
        reload()
    }

    private func performReset() {
        MemoryStore.shared.deleteJournal(character: character)
        MemoryStore.shared.deleteAllTraits(character: character)
        reload()
    }
}

#Preview {
    CompanionJournalView(character: "miku")
}
