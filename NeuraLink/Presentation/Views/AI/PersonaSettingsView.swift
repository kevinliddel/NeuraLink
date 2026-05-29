//
//  PersonaSettingsView.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import AVFoundation
import SwiftUI

// Preview players live in `PersonaVoicePreviewPlayers.swift` to keep this
// file under the project's 525-line ceiling.

// MARK: - View

struct PersonaSettingsView: View {
    let modelID: String
    let selectedConfig: LocalModelDownloadManager.ModelConfiguration
    @State private var persona: CharacterPersona
    @State private var localPrompt: String
    @State private var voicevoxSpeakerID: Int
    @State private var kokoroVoiceID: String
    @Environment(\.dismiss) private var dismiss

    @State private var previewText: String = ""
    @State private var previewPlayer = VoicePreviewPlayer()
    @State private var localPreviewPlayer = LocalTTSPreviewPlayer()
    @State private var isLoadingPreview = false
    // Default-internal so PersonaSettingsView+KokoroDownload can drive
    // the download UX without making the entire view non-private.
    @State var kokoroAvailable: Bool = KokoroModelAccess.isAvailable
    @State var isDownloadingKokoro = false
    @State var kokoroDownloadError: String?

    private let voices = [
        "alloy", "ash", "ballad", "coral", "echo", "marin", "sage", "shimmer", "verse"
    ]

    private var isLocalLLMMode: Bool { OpenAISettings.shared.isLocalLLMEnabled }
    private var isJapaneseModel: Bool { selectedConfig == .japaneseLlama1b }

    /// Whichever player the active mode uses. Centralises the isSpeaking flag.
    private var activeIsSpeaking: Bool {
        isLocalLLMMode ? localPreviewPlayer.isSpeaking : previewPlayer.isSpeaking
    }

    init(modelID: String) {
        self.modelID = modelID
        let config = LocalModelDownloadManager.shared.selectedConfig
        self.selectedConfig = config
        let current = CharacterPersona.forCharacter(named: modelID)
        _persona = State(initialValue: current)
        let prompt = LocalLLMPromptStore.shared.effectivePrompt(for: modelID, config: config)
        _localPrompt = State(initialValue: prompt)
        let initialSpeaker = VoiceVoxSpeaker.speakerID(for: modelID)
        _voicevoxSpeakerID = State(initialValue: initialSpeaker)
        let initialKokoro = KokoroVoicePreset.preset(for: modelID).rawValue
        _kokoroVoiceID = State(initialValue: initialKokoro)

        // Diagnostic: this fires on every NavigationLink push of the persona
        // sheet. If the printed values don't match what you just saved, the
        // bug is in the corresponding store; if they DO match but the UI
        // still shows defaults, the bug is in @State / SwiftUI binding.
        nlLog(
            "[PersonaSettings.init] modelID='\(modelID)' config=\(config) "
            + "→ persona.voice=\(current.voice), instructions.len=\(current.instructions.count); "
            + "localPrompt.len=\(prompt.count); voicevoxSpeaker=\(initialSpeaker); kokoro=\(initialKokoro)",
            level: .info
        )
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

                if isJapaneseModel {
                    voicevoxVoiceSection
                } else {
                    kokoroVoiceSection
                }

                voicePreviewSection
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
                VStack(spacing: 8) {
                    Button {
                        saveChanges()
                        dismiss()
                    } label: {
                        Text("Save Changes")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(12)
                    }
                    // `.borderless` scopes the tap area to the button's label.
                    // Without it, SwiftUI's Form treats the whole row as a
                    // single tappable region and BOTH buttons fire on any
                    // tap — that's how Save was triggering Reset and wiping
                    // the just-saved data. See feedback memory
                    // "swiftui_form_stacked_buttons" for the diagnosis trail.
                    .buttonStyle(.borderless)

                    Button {
                        resetToDefault()
                        dismiss()
                    } label: {
                        Text("Reset to Default")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(12)
                    }
                    .buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
            }
        }
        .navigationTitle(isLocalLLMMode ? "\(persona.name) — \(isJapaneseModel ? "JP Prompt" : "Local Prompt")" : "\(persona.name) Persona")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            previewPlayer.stop()
            localPreviewPlayer.stop()
        }
    }

    // MARK: - Save / Reset

    private func saveChanges() {
        if isLocalLLMMode {
            nlLog(
                "[PersonaSettings.save] LOCAL mode — modelID='\(modelID)' "
                + "localPrompt.len=\(localPrompt.count) "
                + (isJapaneseModel ? "voicevox=\(voicevoxSpeakerID)" : "kokoro=\(kokoroVoiceID)"),
                level: .info
            )
            LocalLLMPromptStore.shared.savePrompt(localPrompt, for: modelID, config: selectedConfig)
            if isJapaneseModel {
                PersonaVoiceStore.shared.setVoicevoxSpeakerID(voicevoxSpeakerID, for: modelID)
            } else {
                PersonaVoiceStore.shared.setKokoroVoiceID(kokoroVoiceID, for: modelID)
            }
            TTSEngineSelector.shared.invalidateCache(for: modelID)
        } else {
            nlLog(
                "[PersonaSettings.save] OPENAI mode — modelID='\(modelID)' "
                + "voice=\(persona.voice) name=\(persona.name) instructions.len=\(persona.instructions.count)",
                level: .info
            )
            PersonaStore.shared.savePersona(persona, for: modelID)
        }
    }

    private func resetToDefault() {
        if isLocalLLMMode {
            LocalLLMPromptStore.shared.resetPrompt(for: modelID, config: selectedConfig)
            localPrompt = LocalLLMPromptStore.shared.effectivePrompt(for: modelID, config: selectedConfig)
            if isJapaneseModel {
                PersonaVoiceStore.shared.clearVoicevoxSpeakerID(for: modelID)
                voicevoxSpeakerID = VoiceVoxSpeaker.speakerID(for: modelID)
            } else {
                PersonaVoiceStore.shared.clearKokoroVoiceID(for: modelID)
                kokoroVoiceID = KokoroVoicePreset.builtInDefault(for: modelID).rawValue
            }
            TTSEngineSelector.shared.invalidateCache(for: modelID)
        } else {
            PersonaStore.shared.resetPersona(for: modelID)
            persona = CharacterPersona.forCharacter(named: modelID)
        }
    }

    // MARK: - Voice Picker Sections

    private var voicevoxVoiceSection: some View {
        Section {
            Picker("Voice", selection: $voicevoxSpeakerID) {
                ForEach(VoiceVoxSpeaker.allBuiltIn) { speaker in
                    Text(speaker.name).tag(speaker.id)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Voice (VOICEVOX)")
        } footer: {
            Text("Used by the Japanese local LLM.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var kokoroVoiceSection: some View {
        Section {
            Picker("Voice", selection: $kokoroVoiceID) {
                ForEach(KokoroVoicePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset.rawValue)
                }
            }
            .pickerStyle(.menu)
            if !kokoroAvailable {
                kokoroDownloadButton
            }
        } header: {
            Text("Voice (Kokoro)")
        } footer: {
            kokoroFooter
        }
    }

    // MARK: - Voice Preview Section

    private var voicePreviewSection: some View {
        Section {
            ZStack(alignment: .bottom) {
                TextField("Enter text to preview…", text: $previewText, axis: .vertical)
                    .font(.headline)
                    .padding(.trailing, 60)
                    .padding(.vertical, 15)
                    .padding(.horizontal, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 25)
                            .stroke(lineWidth: 1.0)
                            .foregroundStyle(Color.clear)
                            .background(
                                Color.gray.opacity(0.12)
                                    .clipShape(RoundedRectangle(cornerRadius: 25))
                            )
                    )
                    .disabled(isLoadingPreview)

                HStack(alignment: .bottom) {
                    Spacer()
                    previewButton
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                }
            }
        } header: {
            Text("Voice Preview")
        } footer: {
            previewFooter
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var previewFooter: some View {
        if isLocalLLMMode {
            if isJapaneseModel {
                Text("Tap the mic to hear your text spoken in the selected VOICEVOX voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if KokoroModelAccess.isAvailable {
                Text("Tap the mic to hear your text spoken in the selected Kokoro voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Kokoro voice pack not installed — install it to enable previews.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        } else {
            let settings = OpenAISettings.shared
            if !settings.isEnabled || !settings.hasValidKey {
                Label(
                    "Add an OpenAI API key in settings to preview voices.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Text("Tap the mic to hear your text spoken in \(persona.voice.capitalized)'s voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var previewButton: some View {
        let isActive = activeIsSpeaking
        let canTap = isActive || (!previewText.trimmingCharacters(in: .whitespaces).isEmpty && previewIsAvailable)

        Button {
            if isActive {
                previewPlayer.stop()
                localPreviewPlayer.stop()
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
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isActive)
            .animation(.easeInOut(duration: 0.18), value: isLoadingPreview)
        }
        .buttonStyle(.borderless)
        .disabled(!canTap || isLoadingPreview)
    }

    /// Whether the current mode has the resources needed to render a preview.
    /// OpenAI: enabled + valid key. Japanese: VoiceVox engine builds unconditionally
    /// (dictionary is bundled). Other local: Kokoro pack present.
    private var previewIsAvailable: Bool {
        if isLocalLLMMode {
            if isJapaneseModel { return true }
            return KokoroModelAccess.isAvailable
        }
        let settings = OpenAISettings.shared
        return settings.isEnabled && settings.hasValidKey
    }

    private func buttonTint(isActive: Bool) -> Color {
        isActive ? .red : .blue
    }

    // MARK: - Preview Logic

    private func startPreview() async {
        let text = previewText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        if isLocalLLMMode {
            await startLocalPreview(text: text)
        } else {
            await startOpenAIPreview(text: text)
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

    /// Synthesises through the local engine that would otherwise run during a
    /// chat turn. Uses temporary `PersonaVoiceStore` overrides to honour the
    /// current picker value even before the user hits Save, then restores any
    /// prior override when synthesis finishes.
    private func startLocalPreview(text: String) async {
        isLoadingPreview = true
        defer { isLoadingPreview = false }

        // Temporarily apply the picker selection so the engine sees it.
        let previousVoicevox = PersonaVoiceStore.shared.voicevoxSpeakerID(for: modelID)
        let previousKokoro = PersonaVoiceStore.shared.kokoroVoiceID(for: modelID)
        if isJapaneseModel {
            PersonaVoiceStore.shared.setVoicevoxSpeakerID(voicevoxSpeakerID, for: modelID)
        } else {
            PersonaVoiceStore.shared.setKokoroVoiceID(kokoroVoiceID, for: modelID)
        }
        TTSEngineSelector.shared.invalidateCache(for: modelID)

        guard let engine = TTSEngineSelector.shared.engine(for: modelID) else {
            nlLog("[Preview] No TTS engine resolved for persona '\(modelID)'", level: .error)
            // Restore overrides before bailing.
            if isJapaneseModel {
                PersonaVoiceStore.shared.setVoicevoxSpeakerID(previousVoicevox, for: modelID)
            } else {
                PersonaVoiceStore.shared.setKokoroVoiceID(previousKokoro, for: modelID)
            }
            TTSEngineSelector.shared.invalidateCache(for: modelID)
            return
        }

        // Save the engine's existing callback (LocalLLMManager wires this up
        // for chat synthesis) so we can restore it when the preview ends.
        // Without this, the next chat turn's PCM buffers would be routed to
        // the freed preview player.
        let previousCallback = engine.onBufferReady
        engine.onBufferReady = { [weak localPreviewPlayer] buffer in
            DispatchQueue.main.async { localPreviewPlayer?.schedule(buffer) }
        }

        do {
            try await engine.initialize()
            try await engine.speak(text, persona: modelID)
        } catch {
            nlLog("[Preview] Local TTS preview failed: \(error)", level: .error)
        }

        // Restore both the engine callback and the persona voice override.
        engine.onBufferReady = previousCallback
        if isJapaneseModel {
            PersonaVoiceStore.shared.setVoicevoxSpeakerID(previousVoicevox, for: modelID)
        } else {
            PersonaVoiceStore.shared.setKokoroVoiceID(previousKokoro, for: modelID)
        }
        TTSEngineSelector.shared.invalidateCache(for: modelID)
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView(modelID: "Ekaterina")
    }
}
