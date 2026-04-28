//
//  AISettingsView.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import SwiftUI

struct AISettingsView: View {
    @Bindable var settings = OpenAISettings.shared
    @State private var downloader = LocalModelDownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                openAISection
                localSLMSection
                interactionSection

                Section {
                    Button("Done") { dismiss() }
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
            Picker("Selected Model", selection: Binding(
                get: { downloader.selectedConfig },
                set: { downloader.selectConfig($0) }
            )) {
                ForEach(LocalModelDownloadManager.ModelConfiguration.allCases) { config in
                    Text(config.rawValue).tag(config)
                }
            }
            .pickerStyle(.segmented)
            .disabled(downloader.state != .notDownloaded && downloader.state != .ready && !downloader.state.isFailed)

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
            Text("Local Edge SLMs")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if ProcessInfo.processInfo.physicalMemory < 6 * 1024 * 1024 * 1024 && downloader.selectedConfig == .qwen2b {
                    Label {
                        Text("This device (4GB RAM) is under the 6GB requirement for Qwen 2B. The 1B model is recommended to prevent crashes.")
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
}
