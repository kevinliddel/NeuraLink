//
//  PersonaSettingsView+Appearance.swift
//  NeuraLink
//
//  "Customize Appearance" entry point inside the per-character settings.
//  The customization panel previews on the live scene, so it can only open
//  for the character currently on screen, and the settings sheet has to be
//  dismissed first (ContentView hosts the panel as an overlay).
//

import SwiftUI

struct AppearanceSettingsSection: View {
    let modelID: String
    @Environment(\.dismiss) private var dismiss

    private var isActiveCharacter: Bool {
        modelID.lowercased() == RealtimeChatState.shared.selectedCharacterName.lowercased()
    }

    var body: some View {
        if isActiveCharacter {
            Section {
                Button {
                    RealtimeChatState.shared.showSettings = false
                    dismiss()
                    CharacterCustomizationCoordinator.shared.present()
                } label: {
                    Label("Customize Appearance", systemImage: "paintpalette")
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("Skin tone, eye and hair colour, and textures borrowed from your other characters — previewed live on the model. Nothing is written to the model file.")
            }
        }
    }
}
