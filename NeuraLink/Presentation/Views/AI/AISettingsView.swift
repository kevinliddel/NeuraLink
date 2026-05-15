//
//  AISettingsView.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import SwiftUI
struct AISettingsView: View {
    @Bindable var settings = OpenAISettings.shared
    @Bindable var appearance = AppearanceSettings.shared
    private var downloader = LocalModelDownloadManager.shared
    private var personaStore = PersonaStore.shared
    @State private var showModelLibrary = false
    @State private var showVADInfo = false
    @State private var showProactiveVisionInfo = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                openAISection
                interactionSection
                personaSection
                localSLMSection
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        triggerConnectionIfNeeded()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var openAISection: some View {
        Section("OpenAI") {
            Toggle("Enable OpenAI", isOn: $settings.isEnabled)

            SecureField("API Key", text: $settings.apiKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(!settings.isEnabled)
        }
    }
    private var localSLMSection: some View {
        Section {
            NavigationLink {
                ModelLibraryView()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model Library")
                            .font(.headline)
                        Text(downloader.selectedConfig.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    stateBadge
                }
            }
            .foregroundStyle(.primary)

            if downloader.isAvailable {
                Toggle("Use Local SLM (Offline)", isOn: $settings.isLocalLLMEnabled)
            }

            if settings.isLocalLLMEnabled {
                Text("Runs completely offline on the Apple Neural Engine. No internet required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Local Edge LLMs")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if ProcessInfo.processInfo.physicalMemory < 6 * 1024 * 1024 * 1024
                    && downloader.selectedConfig == .qwen2b {
                    Label {
                        Text(
                            "This device (4GB RAM) is under the 6GB requirement for Qwen 2B. The 1B model is recommended to prevent crashes."
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                if case .failed(let msg) = downloader.state {
                    Text("Download failed: \(msg)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var personaSection: some View {
        _ = personaStore.lastUpdated // Observe changes
        let modelID = RealtimeChatState.shared.selectedCharacterName
        let persona = CharacterPersona.forCharacter(named: modelID)
        let avatarImage: UIImage? = VRMModelRegistry.all
            .first { $0.name.lowercased() == modelID.lowercased() }
            .flatMap { entry -> UIImage? in
                let pngURL = entry.url.deletingPathExtension().appendingPathExtension("png")
                guard FileManager.default.fileExists(atPath: pngURL.path) else { return nil }
                return UIImage(contentsOfFile: pngURL.path)
            }
        return Section("Character Persona") {
            NavigationLink {
                PersonaSettingsView(modelID: modelID)
            } label: {
                HStack(spacing: 12) {
                    if let img = avatarImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipped()
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    } else {
                        Circle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(persona.name)
                            .font(.headline)
                        Text(settings.isLocalLLMEnabled ? "System Prompt" : "Instructions & Voice")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var interactionSection: some View {
        Section("Autonomy") {
            Toggle(isOn: $settings.isVADEnabled) {
                HStack(spacing: 8) {
                    Text("Auto-Turn Detection (VAD)")
                    Button {
                        showVADInfo = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showVADInfo) {
                        Text("VAD lets OpenAI respond automatically when you stop speaking.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .disabled(!settings.isEnabled)

            Toggle(isOn: $settings.isProactiveVisionEnabled) {
                HStack(spacing: 8) {
                    Text("Proactive Vision")
                    Button {
                        showProactiveVisionInfo = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showProactiveVisionInfo) {
                        Text(
                            "The character periodically looks through the camera and comments on what they see without being asked."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .disabled(!settings.isEnabled)
            .listRowSeparator(settings.isEnabled && settings.isProactiveVisionEnabled ? .hidden : .automatic)

            if settings.isEnabled && settings.isProactiveVisionEnabled {
                HStack {
                    Text("Interval")
                    Spacer()
                    Picker("Interval", selection: $settings.proactiveVisionIntervalSec) {
                        Text("10s").tag(10.0)
                        Text("20s").tag(20.0)
                        Text("30s").tag(30.0)
                        Text("60s").tag(60.0)
                    }
                    .labelsHidden()
                }
                .listRowSeparator(.hidden)

                HStack {
                    Text("Cooldown after speech")
                    Spacer()
                    Picker("Cooldown", selection: $settings.proactiveVisionCooldownAfterSpeechSec) {
                        Text("0s").tag(0.0)
                        Text("8s").tag(8.0)
                        Text("12s").tag(12.0)
                        Text("20s").tag(20.0)
                    }
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var stateBadge: some View {
        switch downloader.state {
        case .bundled:
            Label("Built-in", systemImage: "checkmark.seal.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
        case .downloading:
            Label("Downloading…", systemImage: "arrow.down.circle")
                .font(.caption.bold())
                .foregroundStyle(.blue)
        case .paused:
            Label("Paused", systemImage: "pause.circle")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
        case .notDownloaded:
            Label("Not downloaded", systemImage: "arrow.down.circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch downloader.state {
        case .notDownloaded, .failed:
            Button {
                downloader.startDownload()
            } label: {
                Label("Download Model", systemImage: "arrow.down.circle")
            }
        case .downloading:
            Button {
                downloader.pauseDownload()
            } label: {
                Label("Pause Download", systemImage: "pause.circle")
            }
        case .paused:
            HStack {
                Button {
                    downloader.resumeDownload()
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                Button(role: .cancel) {
                    downloader.cancelDownload()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
            }
        case .bundled, .ready:
            EmptyView()
        }
    }

    private func downloadPhaseLabel(progress: Double) -> String {
        let pct = Int(progress * 100)
        if progress < 0.9 {
            return "Downloading… \(pct)%"
        } else {
            return "Compiling for Neural Engine… \(pct)%"
        }
    }

    private func triggerConnectionIfNeeded() {
        if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.connect()
        } else if settings.isLocalLLMEnabled && LocalModelDownloadManager.shared.isAvailable {
            LocalLLMManager.shared.startListening()
        }
    }
}
