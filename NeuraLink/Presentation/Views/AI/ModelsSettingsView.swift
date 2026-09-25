//
//  ModelsSettingsView.swift
//  NeuraLink
//
//  Dedicated screen for the OpenAI model choices, pushed from AISettingsView
//  (same pattern as AutonomySettingsView). One section per role, each with
//  its catalog picker + custom id, and a usage section fed by the Realtime
//  token meter (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B3).
//
//  Created by Dedicatus on 26/09/2026.
//

import SwiftUI

struct ModelsSettingsView: View {
    @Bindable var settings = OpenAISettings.shared
    @State private var aiState = RealtimeChatState.shared

    var body: some View {
        Form {
            roleSection(.realtime, footer: "Used for the live voice conversation. A change applies when the session reconnects (tap Done in AI Settings).")
            roleSection(.transcription, footer: "Turns your speech into text for the voice model and the chat history.")
            roleSection(.text, footer: "Background work that never speaks: memory extraction, summaries, chat titles and end-of-session reflections.")
            usageSection
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!settings.isEnabled)
    }

    private func roleSection(_ role: OpenAIModelCatalog.Role, footer: String) -> some View {
        Section {
            ModelPickerRow(role: role, settings: settings)
        } header: {
            Text(role.title)
        } footer: {
            Text(footer)
        }
    }

    private var usageSection: some View {
        Section {
            usageRow("This session", meter: aiState.sessionUsage)
            usageRow("Last session", meter: aiState.lastSessionUsage)
        } header: {
            Text("Usage")
        } footer: {
            Text("Token counts reported by OpenAI for the voice sessions; text calls are logged under [Cost].")
        }
    }

    private func usageRow(_ title: String, meter: RealtimeUsageMeter) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(meter.responses > 0 ? meter.summary : "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
