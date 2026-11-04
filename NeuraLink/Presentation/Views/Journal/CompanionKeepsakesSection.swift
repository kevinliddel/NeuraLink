//
//  CompanionKeepsakesSection.swift
//  NeuraLink
//
//  "Keepsakes" section of the companion's journal — Living Companion
//  (docs/LIVING_COMPANION.md): the shared firsts the user and the character
//  have collected, as badges; the ones still ahead are dimmed.
//
//  Created by Dedicatus on 12/10/2026.
//

import SwiftUI

struct CompanionKeepsakesSection: View {
    let character: String

    @State private var collected: [CompanionMilestone] = []

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(MilestoneKind.allCases, id: \.rawValue) { kind in
                    KeepsakeBadge(kind: kind, milestone: collected.first { $0.kind == kind })
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Keepsakes")
        } footer: {
            Text(footerLine)
        }
        .onAppear(perform: reload)
    }

    private var footerLine: String {
        collected.isEmpty
            ? "Shared firsts you collect together appear here."
            : "\(collected.count) of \(MilestoneKind.allCases.count) collected."
    }

    private func reload() {
        // Count-based keepsakes may have unlocked since the meter last moved.
        CompanionMilestoneTracker.refreshDerived(character: character)
        collected = MemoryStore.shared.milestones(character: character)
    }
}

private struct KeepsakeBadge: View {
    let kind: MilestoneKind
    let milestone: CompanionMilestone?

    private var isCollected: Bool { milestone != nil }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(
                    isCollected ? Color.pink.opacity(0.18) : Color.secondary.opacity(0.12),
                    in: Circle()
                )
                .foregroundStyle(isCollected ? Color.pink : Color.secondary)
            Text(kind.title)
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(dateLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .opacity(isCollected ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title), \(isCollected ? "collected" : "not yet")")
        .accessibilityHint(kind.detail)
    }

    private var dateLine: String {
        guard let milestone else { return "Not yet" }
        return milestone.achievedAt.formatted(.dateTime.day().month())
    }
}

#Preview {
    Form { CompanionKeepsakesSection(character: "miku") }
}
