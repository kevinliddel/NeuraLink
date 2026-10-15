//
//  MemoryModelTile.swift
//  NeuraLink
//
//  One "About you" / "Between you" summary on the Memory page's hero card
//  (docs/MEMORY_OWNERSHIP.md). A mental model can run to ninety words, and
//  two of them turned the card into a wall of text: each now sits in its
//  own tile, clamped to a few lines, and expands on tap. The "More"
//  affordance only appears when the text really is cut off.
//
//  Created by Dedicatus on 13/10/2026.
//

import SwiftUI

struct MemoryModelTile: View {
    let title: String
    let symbol: String
    let text: String

    static let collapsedLines = 3

    @State private var isExpanded = false
    @State private var isTruncated = false

    private var canToggle: Bool { isTruncated || isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if canToggle {
                    Text(isExpanded ? "Less" : "More")
                        .font(.caption2.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .foregroundStyle(.white.opacity(0.75))

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .background(truncationProbe)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
        .onTapGesture {
            guard canToggle else { return }
            withAnimation(.snappy) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canToggle ? .isButton : [])
        .accessibilityHint(canToggle ? (isExpanded ? "Collapses the summary" : "Shows the whole summary") : "")
    }

    /// Lays the full text out invisibly at the same width and compares its
    /// height with the clamped text's, so short summaries get no "More".
    private var truncationProbe: some View {
        GeometryReader { clamped in
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { full in
                        Color.clear
                            .onAppear { isTruncated = full.size.height > clamped.size.height + 1 }
                            .onChange(of: full.size.height) { _, height in
                                isTruncated = height > clamped.size.height + 1
                            }
                    }
                )
                .hidden()
        }
        .hidden()
    }
}

#Preview {
    VStack(spacing: 10) {
        MemoryModelTile(title: "About you", symbol: "person.crop.circle", text: "Likes coffee and long walks.")
        MemoryModelTile(
            title: "Between you", symbol: "person.2.fill",
            text: String(repeating: "You two talk most evenings about music, work and the weather in Antananarivo. ", count: 4))
    }
    .padding()
    .background(.purple)
}
