//
//  AISettingsView.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import SwiftUI
import PhotosUI
struct AISettingsView: View {
    @Bindable var settings = OpenAISettings.shared
    @Bindable var appearance = AppearanceSettings.shared
    @State private var downloader = LocalModelDownloadManager.shared
    @State private var personaStore = PersonaStore.shared
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var backgroundImage: UIImage? = AppearanceSettings.shared.backgroundUIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                openAISection
                localSLMSection
                personaSection
                appearanceSection
                interactionSection

                Section {
                    Button("Done") {
                        triggerConnectionIfNeeded()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("AI Settings")
            .navigationBarTitleDisplayMode(.inline)
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

            Toggle("Auto-Turn Detection (VAD)", isOn: $settings.isVADEnabled)
                .disabled(!settings.isEnabled)

            if settings.isEnabled {
                Text("VAD lets OpenAI respond automatically when you stop speaking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var localSLMSection: some View {
        Section {
            // Model Selection Picker
            Picker(
                "Selected Model",
                selection: Binding(
                    get: { downloader.selectedConfig },
                    set: { newConfig in
                        downloader.selectConfig(newConfig)
                        if settings.isLocalLLMEnabled {
                            LocalLLMManager.shared.restart()
                        }
                    }
                )
            ) {
                ForEach(LocalModelDownloadManager.ModelConfiguration.allCases) { config in
                    Text(config.rawValue).tag(config)
                }
            }
            .pickerStyle(.segmented)
            .disabled(
                downloader.state != .notDownloaded && downloader.state != .ready
                    && !downloader.state.isFailed)

            // Header row: model name + status badge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(downloader.selectedConfig.rawValue)
                        .font(.headline)
                    Text(
                        "~\(String(format: "%.1f", downloader.selectedConfig.estimatedSizeGB)) GB · \(downloader.selectedConfig.description)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                stateBadge
            }
            .padding(.vertical, 4)

            // Download progress bar
            if case .downloading(let progress) = downloader.state {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .tint(.blue)
                    Text(downloadPhaseLabel(progress: progress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Action button
            actionButton

            // Enable toggle (only available when model is ready)
            if downloader.isAvailable {
                Toggle("Use Local SLM (Offline)", isOn: $settings.isLocalLLMEnabled)
            }

            if settings.isLocalLLMEnabled {
                Text("Runs completely offline on the Apple Neural Engine. No internet required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Delete option when downloaded (not bundled)
            if case .ready = downloader.state {
                Button(role: .destructive) {
                    settings.isLocalLLMEnabled = false
                    downloader.deleteDownloadedModel()
                } label: {
                    Label("Delete Downloaded Model", systemImage: "trash")
                }
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

    private var appearanceSection: some View {
        Section("Appearance") {
            Toggle("Show 3D Environment", isOn: $appearance.showEnvironment)
            
            if !appearance.showEnvironment {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                    HStack {
                        Text("Custom Background")
                        Spacer()
                        if let img = backgroundImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    Task {
                        guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
                        appearance.saveBackgroundImage(data)
                        if let uiImage = UIImage(data: data) {
                            await MainActor.run {
                                backgroundImage = uiImage
                            }
                        }
                    }
                }
                
                if backgroundImage != nil {
                    Button(role: .destructive) {
                        appearance.saveBackgroundImage(nil)
                        backgroundImage = nil
                        selectedPhotoItem = nil
                    } label: {
                        Text("Clear Custom Background")
                    }
                }
                
                Text("Turn off Show 3D Environment and select a screenshot of your Home Screen to use as a Fake Home Screen background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var interactionSection: some View {
        EmptyView()  // VAD is now inline in the OpenAI section
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
            Button(role: .cancel) {
                downloader.cancelDownload()
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
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
