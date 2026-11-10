//
//  CompanionLoreSection.swift
//  NeuraLink
//
//  "Their stories" in the journal — Inner life
//  (docs/Companion/LIVING_COMPANION.md): what the character has shared
//  about itself so far, by tier, newest first. Only characters with
//  authored lore get the section.
//
//  Created by Dedicatus on 05/11/2026.
//

import SwiftUI

struct CompanionLoreSection: View {
    let character: String
    let displayName: String
    let reveals: [LoreReveal]

    private var fragments: [LoreFragment] {
        CharacterStoryProvider.shared.fragments(for: character)
    }

    /// Revealed fragments in reveal order, dropping ids the catalogue no
    /// longer has.
    private var shared: [(fragment: LoreFragment, at: Date)] {
        reveals.compactMap { reveal in
            fragments.first { $0.id == reveal.fragmentID }.map { ($0, reveal.revealedAt) }
        }
    }

    var body: some View {
        if !fragments.isEmpty {
            Section {
                if shared.isEmpty {
                    Text("Nothing yet — \(displayName) opens up as you grow closer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shared, id: \.fragment.id) { item in
                        row(item.fragment, at: item.at)
                    }
                }
            } header: {
                Text("Their stories")
            } footer: {
                Text("What \(displayName) has shared from their own life: \(shared.count) of \(fragments.count).")
            }
        }
    }

    private func row(_ fragment: LoreFragment, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text("\(fragment.tier.title) · \(date.formatted(.dateTime.day().month()))")
            } icon: {
                Image(systemName: fragment.tier.symbol)
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.Tint.keepsake)
            Text(fragment.text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}
