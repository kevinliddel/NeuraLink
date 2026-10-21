//
//  PersonaSettingsView+Imported.swift
//  NeuraLink
//
//  The rows only an imported character has: its card image and its gender
//  (CharacterGender — which idle, resting and pose clips the body uses).
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
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView(modelID: "Ekaterina")
    }
}
