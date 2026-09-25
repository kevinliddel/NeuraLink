//
//  MemoryInsightsSection.swift
//  NeuraLink
//
//  Building blocks for the Memory page: the hero card (relationship,
//  counts, what the companion currently knows) and the observations list
//  fed by the agentic memory layer (docs/AGENTIC_MEMORY.md).
//
//  Created by Dedicatus on 25/09/2026.
//

import SwiftUI

// MARK: - Snapshot

/// Everything the Memory page shows, loaded in one pass off the main
/// thread so the sheet opens without stutter.
struct MemoryPageSnapshot {
    var facts = 0
    var observations = 0
    var moments = 0
    var models: [MentalModel] = []
    var observationUnits: [MemoryUnit] = []

    static func load(character: String) -> MemoryPageSnapshot {
        let store = MemoryStore.shared
        var snapshot = MemoryPageSnapshot()
        snapshot.facts = store.countFacts() + store.countUnits(factType: .world) + store.countUnits(factType: .experience)
        snapshot.observations = store.countUnits(factType: .observation)
        snapshot.moments = store.countUnits(factType: .raw)
        snapshot.models = store.fetchMentalModels(character: character).filter { !$0.content.isEmpty }
        snapshot.observationUnits = store.fetchUnits(factTypes: [.observation])
        return snapshot
    }
}

// MARK: - Hero card

struct MemoryHeroCard: View {
    let characterName: String
    let snapshot: MemoryPageSnapshot
    let isEnabled: Bool
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var companion = CompanionStateStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "brain")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(characterName)'s memory")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                        Text(companion.label)
                            .font(.caption.weight(.semibold))
                        ProgressView(value: companion.score)
                            .tint(.white)
                            .frame(width: 70)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                MemoryStatTile(value: snapshot.facts, label: "Facts", symbol: "checkmark.seal.fill")
                MemoryStatTile(value: snapshot.observations, label: "Insights", symbol: "sparkles")
                MemoryStatTile(value: snapshot.moments, label: "Moments", symbol: "bubble.left.and.bubble.right.fill")
            }

            Divider().overlay(.white.opacity(0.25))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("WHAT \(characterName.uppercased()) KNOWS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button(action: onRefresh) {
                        HStack(spacing: 4) {
                            if isRefreshing {
                                ProgressView().tint(.white).scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isRefreshing ? "Updating" : "Update")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshing || !isEnabled)
                }

                if snapshot.models.isEmpty {
                    Text(isEnabled
                         ? "Still getting to know you. Summaries appear here after a few conversations."
                         : "Memory is paused. Turn it on below to start remembering.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    ForEach(snapshot.models) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.slug == MemoryMentalModels.userProfileSlug ? "About you" : "Between you")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(model.content)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.22, blue: 0.86), Color(red: 0.62, green: 0.20, blue: 0.72),
                         Color(red: 0.90, green: 0.32, blue: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .purple.opacity(0.25), radius: 14, y: 6)
        .onAppear { companion.refresh() }
    }
}

struct MemoryStatTile: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
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

// MARK: - Observations

struct MemoryObservationRow: View {
    let unit: MemoryUnit

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.purple)
                .frame(width: 28, height: 28)
                .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(unit.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label("\(unit.proofCount) source\(unit.proofCount == 1 ? "" : "s")", systemImage: "link")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.1), in: Capsule())
                    Text(Self.dateFormatter.string(from: unit.mentionedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Friendly placeholder for an empty list section.
struct MemoryEmptyRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
