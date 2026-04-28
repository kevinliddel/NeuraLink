//
//  PersonaSettingsView.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import SwiftUI

struct PersonaSettingsView: View {
    let modelID: String
    @State private var persona: CharacterPersona
    @Environment(\.dismiss) private var dismiss
    
    // Supported voices for OpenAI Realtime
    private let voices = ["alloy", "echo", "shimmer", "ash", "ballad", "coral", "sage", "verse", "marin"]

    init(modelID: String) {
        self.modelID = modelID
        // Initialize with current persona (cached or default)
        let current = CharacterPersona.forCharacter(named: modelID)
        _persona = State(initialValue: current)
    }

    var body: some View {
        Form {
            Section("Display Name") {
                TextField("Name", text: $persona.name)
            }

            Section("AI Instructions (System Prompt)") {
                TextEditor(text: $persona.instructions)
                    .frame(minHeight: 200)
                    .font(.system(.footnote))
            }

            Section("Voice") {
                Picker("Voice", selection: $persona.voice) {
                    ForEach(voices, id: \.self) { voice in
                        Text(voice.capitalized).tag(voice)
                    }
                }
            }

            Section {
                Button("Save Changes") {
                    PersonaStore.shared.savePersona(persona, for: modelID)
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.blue)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                Button("Reset to Default", role: .destructive) {
                    PersonaStore.shared.resetPersona(for: modelID)
                    let defaults = CharacterPersona.forCharacter(named: modelID)
                    persona = defaults
                    dismiss()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("\(persona.name) Persona")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView(modelID: "Ekaterina")
    }
}
