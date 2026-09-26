//
//  MemoryRecapCard.swift
//  NeuraLink
//
//  "This week with <character>" card (docs/MEMORY_OWNERSHIP_PLAN.md §M1),
//  fed by the weekly recap mental model. Dismissable per ISO week.
//

import SwiftUI

struct MemoryRecapCard: View {
    let characterName: String
    let content: String
    let onAsk: () -> Void
    let onDismiss: () -> Void

    private var parts: (summary: String, ask: String) { MemoryMentalModels.recapParts(content) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("This week with \(characterName)", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss recap")
            }
            Text(parts.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if !parts.ask.isEmpty {
                Button(action: onAsk) {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                        Text("Ask about it")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Per-week dismissal state.
    enum Dismissal {
        private static let key = "com.neuralink.memory.recap.dismissedWeek"
        static func isDismissed(now: Date = Date()) -> Bool {
            UserDefaults.standard.string(forKey: key) == MemoryMentalModels.weekKey(for: now)
        }
        static func dismiss(now: Date = Date()) {
            UserDefaults.standard.set(MemoryMentalModels.weekKey(for: now), forKey: key)
        }
    }
}
