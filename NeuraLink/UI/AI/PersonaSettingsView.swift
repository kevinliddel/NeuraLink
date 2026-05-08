//
//  PersonaSettingsView.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import AVFoundation
import SwiftUI

// MARK: - Voice Preview Player

@Observable
private final class VoicePreviewPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var isSpeaking = false
    private var player: AVAudioPlayer?

    func start(data: Data) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.play()
            isSpeaking = true
        } catch {
            isSpeaking = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isSpeaking = false
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        player = nil
        isSpeaking = false
    }

    deinit { player?.stop() }
}

// MARK: - View

struct PersonaSettingsView: View {
    let modelID: String
    let selectedConfig: LocalModelDownloadManager.ModelConfiguration
    @State private var persona: CharacterPersona
    @State private var localPrompt: String
    @Environment(\.dismiss) private var dismiss

    // Voice preview (OpenAI mode only)
    @State private var previewText: String = ""
    @State private var previewPlayer = VoicePreviewPlayer()
    @State private var isLoadingPreview = false

    private let voices = [
        "alloy", "echo", "shimmer", "ash", "ballad", "coral", "sage", "verse", "marin"
    ]

    private var isLocalLLMMode: Bool { OpenAISettings.shared.isLocalLLMEnabled }
    private var isJapaneseModel: Bool { selectedConfig == .japaneseLlama1b }

    init(modelID: String) {
        self.modelID = modelID
        let config = LocalModelDownloadManager.shared.selectedConfig
        self.selectedConfig = config
        let current = CharacterPersona.forCharacter(named: modelID)
        _persona = State(initialValue: current)
        _localPrompt = State(initialValue: LocalLLMPromptStore.shared.effectivePrompt(for: modelID, config: config))
    }

    var body: some View {
        Form {
            Section("Display Name") {
                TextField("Name", text: $persona.name)
            }

            if isLocalLLMMode {
                Section {
                    TextEditor(text: $localPrompt)
                        .frame(minHeight: 200)
                        .font(.system(.footnote))
                } header: {
                    Text(isJapaneseModel ? "System Prompt (Local LLM · Japanese)" : "System Prompt (Local LLM)")
                } footer: {
                    Text(
                        isJapaneseModel
                            ? "日本語モデル用のプロンプトです。簡潔な話し言葉で記述してください。"
                            : "This prompt is used by the on-device model. Keep it short and conversational — small models follow explicit spoken-word instructions best."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Section("AI Instructions (System Prompt)") {
                    TextEditor(text: $persona.instructions)
                        .frame(minHeight: 200)
                        .font(.system(.footnote))
                }

                Section("Voice") {
                    Picker("Voice", selection: $persona.voice) {
                        ForEach(voices, id: \.self) { voice in
                            Text(voice.capitalized).tag(voice)
                        }
                    }
                }

                voicePreviewSection
            }

            Section {
                Button("Save Changes") {
                    if isLocalLLMMode {
                        LocalLLMPromptStore.shared.savePrompt(localPrompt, for: modelID, config: selectedConfig)
                    } else {
                        PersonaStore.shared.savePersona(persona, for: modelID)
                    }
                    dismiss()
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.blue)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                Button("Reset to Default", role: .destructive) {
                    if isLocalLLMMode {
                        LocalLLMPromptStore.shared.resetPrompt(for: modelID, config: selectedConfig)
                        localPrompt = LocalLLMPromptStore.shared.effectivePrompt(for: modelID, config: selectedConfig)
                    } else {
                        PersonaStore.shared.resetPersona(for: modelID)
                        persona = CharacterPersona.forCharacter(named: modelID)
                    }
                    dismiss()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(isLocalLLMMode ? "\(persona.name) — \(isJapaneseModel ? "JP Prompt" : "Local Prompt")" : "\(persona.name) Persona")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { previewPlayer.stop() }
    }

    // MARK: - Voice Preview Section

    private var voicePreviewSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                TextField("Enter text to preview…", text: $previewText)
                    .controlSize(.regular)
                    .disabled(isLoadingPreview)

                previewButton
            }
        } header: {
            Text("Voice Preview")
        } footer: {
            let isLocalEnabled = OpenAISettings.shared.isLocalLLMEnabled
            if !isLocalEnabled {
                let settings = OpenAISettings.shared
                if !settings.isEnabled || !settings.hasValidKey {
                    Label(
                        "Add an OpenAI API key in settings to preview voices.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(
                        "Tap the mic to hear your text spoken in \(persona.voice.capitalized)'s voice."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                let ready = VoiceVoxModelManager.shared.isDictionaryAvailable
                if !ready {
                    Label("VOICEVOX dictionary not found in bundle.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Tap the mic to synthesize Japanese text locally via VOICEVOX.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var voicevoxSection: some View {
        Section("VOICEVOX Character") {
            let speakers = VoiceVoxSpeaker.allBuiltIn
            
            Picker("Character", selection: Binding(
                get: { persona.ttsSpeakerID ?? 3 }, // Default to Zundamon
                set: { persona.ttsSpeakerID = $0 }
            )) {
                ForEach(speakers) { speaker in
                    Text(speaker.name).tag(speaker.id)
                }
            }

            if let selectedSpeaker = speakers.first(where: { $0.id == (persona.ttsSpeakerID ?? 3) }) {
                Picker("Style", selection: Binding(
                    get: { persona.ttsSpeakerID ?? selectedSpeaker.styles[0].id },
                    set: { persona.ttsSpeakerID = $0 }
                )) {
                    ForEach(selectedSpeaker.styles) { style in
                        Text(style.name).tag(style.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var previewButton: some View {
        let isActive = previewPlayer.isSpeaking
        let isLocalEnabled = OpenAISettings.shared.isLocalLLMEnabled
        let canTapOpenAI = !isLocalEnabled
            && !previewText.trimmingCharacters(in: .whitespaces).isEmpty
            && OpenAISettings.shared.isEnabled && OpenAISettings.shared.hasValidKey
        
        let canTapVoiceVox = isLocalEnabled
            && !previewText.trimmingCharacters(in: .whitespaces).isEmpty
            && VoiceVoxModelManager.shared.isDictionaryAvailable

        let canTap = isActive || canTapOpenAI || canTapVoiceVox

        Button {
            if isActive {
                previewPlayer.stop()
            } else {
                Task { await startPreview() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(buttonTint(isActive: isActive).opacity(0.12))
                    .frame(width: 40, height: 40)

                if isLoadingPreview {
                    ProgressView()
                        .tint(Color.secondary)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(buttonTint(isActive: isActive))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .animation(.easeInOut(duration: 0.18), value: isLoadingPreview)
        }
        .buttonStyle(.borderless)
        .disabled(!canTap || isLoadingPreview)
    }

    private func buttonTint(isActive: Bool) -> Color {
        isActive ? .red : .blue
    }

    // MARK: - Preview Logic

    private func startPreview() async {
        let text = previewText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        if !OpenAISettings.shared.isLocalLLMEnabled {
            await startOpenAIPreview(text: text)
        } else {
            await startVoiceVoxPreview(text: text)
        }
    }

    private func startOpenAIPreview(text: String) async {
        let settings = OpenAISettings.shared
        guard settings.isEnabled && settings.hasValidKey else { return }

        isLoadingPreview = true
        defer { isLoadingPreview = false }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": persona.voice
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return }

        previewPlayer.start(data: data)
    }

    private func startVoiceVoxPreview(text: String) async {
        isLoadingPreview = true
        defer { isLoadingPreview = false }

        let engine = VoiceVoxEngine.shared
        do {
            try await engine.initialize()
            let speakerID = persona.ttsSpeakerID ?? 3
            let data = try await engine.synthesize(text: text, speakerID: speakerID)
            previewPlayer.start(data: data)
        } catch {
            print("[VoiceVox] Preview failed: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView(modelID: "Ekaterina")
    }
}
