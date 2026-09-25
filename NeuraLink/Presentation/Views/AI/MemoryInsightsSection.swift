//
//  MemoryInsightsSection.swift
//  NeuraLink
//
//  Memory sheet sections for the agentic memory layer: what the companion
//  currently believes (mental models) and the consolidated observations
//  behind it, with per-row delete and a manual "Update now" action.
//
//  Created by Dedicatus on 25/09/2026.
//

import SwiftUI

struct MemoryInsightsSection: View {
    @State private var models: [MentalModel] = []
    @State private var observations: [MemoryUnit] = []
    @State private var isRefreshing = false

    private let maxObservations = 20

    var body: some View {
        Section {
            if models.isEmpty {
                Text("Nothing summarised yet — it updates in the background after a few conversations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.slug == MemoryMentalModels.userProfileSlug ? "About you" : "Our relationship")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(model.content)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            HStack {
                Text("What \(characterName) knows")
                Spacer()
                Button(isRefreshing ? "Updating…" : "Update now") { refreshNow() }
                    .font(.caption)
                    .disabled(isRefreshing)
            }
            .textCase(nil)
        } footer: {
            Text("Summaries are rebuilt on-device from the observations below; recall combines meaning, keywords, people/places and dates.")
        }

        Section {
            if observations.isEmpty {
                Text("No observations yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(observations) { unit in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(unit.text)
                                .font(.subheadline)
                            Text("evidence ×\(unit.proofCount) · \(Self.dateFormatter.string(from: unit.mentionedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            MemoryStore.shared.deleteUnit(id: unit.id)
                            MemoryStore.shared.markMentalModelsStale()
                            reload()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red.opacity(0.75))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Observations (\(observations.count))")
                .textCase(nil)
        }
        .onAppear(perform: reload)
    }

    private var characterName: String {
        let name = RealtimeChatState.shared.selectedCharacterName
        return name.isEmpty ? "the assistant" : name.capitalized
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func reload() {
        let character = RealtimeChatState.shared.selectedCharacterName
        models = MemoryStore.shared.fetchMentalModels(character: character).filter { !$0.content.isEmpty }
        observations = Array(MemoryStore.shared.fetchUnits(factTypes: [.observation]).prefix(maxObservations))
    }

    /// Flushes pending turns, consolidates, and rebuilds the summaries.
    private func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let character = RealtimeChatState.shared.selectedCharacterName
        Task.detached(priority: .userInitiated) {
            await MemoryConsolidator.shared.consolidatePending()
            MemoryStore.shared.markMentalModelsStale()
            await MemoryMentalModels.shared.refreshStale(character: character)
            await MainActor.run {
                reload()
                isRefreshing = false
            }
        }
    }
}
