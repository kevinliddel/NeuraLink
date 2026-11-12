//
//  PersonaSettingsView+Imported.swift
//  NeuraLink
//
//  The rows only an imported character has: its card image, its gender
//  (CharacterGender — which idle, resting and pose clips the body uses)
//  and the editor of its story sheet.
//  Bundled characters get both from the registry and show neither.
//
//  Created by Dedicatus on 20/10/2026.
//

import SwiftUI

extension PersonaSettingsView {

    @ViewBuilder
    var importedCharacterSections: some View {
        CharacterImageSection(slug: modelID.lowercased())
        Section {
            GenderSquarePicker(selection: $gender)
        } header: {
            Text("Gender")
        } footer: {
            Text("Picks the idle, resting and photo-pose animations. Applies the next time the character is loaded.")
        }
        Section {
            NavigationLink("Their story") {
                CharacterStoryEditorView(character: modelID.lowercased(), displayName: persona.name)
            }
        } footer: {
            Text("The life this character talks from: habits, tastes, people, the stories they share as you grow closer.")
        }
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView(modelID: "Ekaterina")
    }
}
