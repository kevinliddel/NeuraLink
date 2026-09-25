//
//  PersonaSettingsView+Disposition.swift
//  NeuraLink
//
//  "Memory personality" section for a character: the Hindsight-style
//  disposition traits that steer consolidation, mental models and reflect
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C4). Kept in its own file because
//  PersonaSettingsView sits at the file-length limit.
//

import SwiftUI

struct DispositionSection: View {
    let character: String
    @State private var disposition: MemoryDisposition

    init(character: String) {
        self.character = character
        _disposition = State(initialValue: MemoryDisposition.forCharacter(character))
    }

    var body: some View {
        Section {
            traitSlider("Skepticism", value: $disposition.skepticism, low: "Trusting", high: "Skeptical")
            traitSlider("Literalism", value: $disposition.literalism, low: "Reads between lines", high: "Literal")
            traitSlider("Empathy", value: $disposition.empathy, low: "Just the facts", high: "Emotion-aware")
            let preview = disposition.promptDescription
            Text(preview.isEmpty ? "Neutral: no special instruction is added." : preview)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset to neutral") { update(.neutral) }
                .font(.footnote)
                .disabled(disposition == .neutral)
        } header: {
            Text("Memory Personality")
        } footer: {
            Text("How \(character.capitalized) weighs what it hears when it turns conversations into memories. Affects summaries and beliefs, not what is recalled.")
        }
    }

    private func traitSlider(_ title: String, value: Binding<Int>, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)/5")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { newValue in
                        value.wrappedValue = Int(newValue.rounded())
                        update(disposition)
                    }),
                in: 1...5, step: 1)
            HStack {
                Text(low).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(high).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func update(_ value: MemoryDisposition) {
        disposition = value
        value.save(forCharacter: character)
        OpenAIRealtimeManager.postInstructionsChanged(reason: "disposition")
    }
}
