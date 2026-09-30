//
//  ModelsSettingsView.swift
//  NeuraLink
//
//  Dedicated screen for the OpenAI model choices, pushed from AISettingsView
//  (same pattern as AutonomySettingsView). One section per role, each with
//  its curated catalog picker (docs/CHAT_LLM.md).
//
//  Created by Dedicatus on 26/09/2026.
//

import SwiftUI

struct ModelsSettingsView: View {
    @Bindable var settings = OpenAISettings.shared

    var body: some View {
        Form {
            roleSection(.realtime, info: "Used for the live voice conversation. A change applies when the session reconnects (tap Done in AI Settings).")
            roleSection(.transcription, info: "Turns your speech into text for the voice model and the chat history.")
            roleSection(.text, info: "Background work that never speaks: memory extraction, summaries, chat titles and end-of-session reflections.")
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!settings.isEnabled)
    }

    private func roleSection(_ role: OpenAIModelCatalog.Role, info: String) -> some View {
        Section {
            ModelPickerRow(role: role, settings: settings)
        } header: {
            InfoToggleLabel(title: role.title, info: info)
                .textCase(nil)
        }
    }
}
