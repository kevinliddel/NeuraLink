//
//  AISettingsView.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import SwiftUI

struct AISettingsView: View {
    @Bindable var settings = OpenAISettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Local Edge AI") {
                    Toggle("Enable Local SLM (NPU)", isOn: $settings.isLocalLLMEnabled)
                    Text(
                        "Runs completely offline using the Apple Neural Engine. Slow but private, and requires no internet."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("OpenAI") {
                    Toggle("Enable OpenAI Integration", isOn: $settings.isEnabled)

                    SecureField("OpenAI API Key", text: $settings.apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(!settings.isEnabled)
                }

                Section("Interaction Settings") {
                    Toggle("Auto-Turn Detection (VAD)", isOn: $settings.isVADEnabled)

                    Text(
                        "When VAD is enabled, OpenAI will automatically respond when you stop speaking."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Button("Done") { dismiss() }
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
