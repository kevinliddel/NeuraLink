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
    @Bindable var presence = PresenceSettings.shared
    private var downloader = LocalModelDownloadManager.shared
    private var personaStore = PersonaStore.shared
    @State private var showModelLibrary = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                openAISection
                interactionSection
                personaSection
                localSLMSection
            }
            .scrollIndicators(.hidden)
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
                if let warning = ramWarning(for: downloader.selectedConfig) {
                    Label {
                        Text(warning)
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

    /// Returns a warning when the selected model exceeds the device's safe RAM
    /// headroom. Both shipped local models (Llama-1B, LLM-jp-3) are sized for the
    /// 4 GB tier, so there's nothing to warn about today.
    private func ramWarning(for config: LocalModelDownloadManager.ModelConfiguration) -> String? {
        nil
    }

    private var personaSection: some View {
        _ = personaStore.lastUpdated // Observe changes
        let modelID = RealtimeChatState.shared.selectedCharacterName
        let persona = CharacterPersona.forCharacter(named: modelID)
        let avatarImage: UIImage? = VRMModelRegistry.shared.all
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

    /// Compact entry row (persona-row pattern) — the toggles themselves live
    /// in AutonomySettingsView, one titled section per feature.
    private var interactionSection: some View {
        Section("Autonomy") {
            NavigationLink {
                AutonomySettingsView()
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.85), .blue.opacity(0.7)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Autonomy")
                            .font(.headline)
                        Text(autonomySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One-line status of the autonomous features, shown under the row title.
    private var autonomySummary: String {
        var active: [String] = []
        if settings.isEnabled && settings.isVADEnabled { active.append("VAD") }
        if settings.isEnabled && settings.isProactiveVisionEnabled { active.append("Vision") }
        if presence.isPresenceEnabled { active.append("Presence") }
        if presence.isProactiveEngagementEnabled { active.append("Engagement") }
        return active.isEmpty ? "Everything off — tap to configure" : active.joined(separator: " · ")
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
