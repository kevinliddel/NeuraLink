//
//  TranscriptSpeechPlayer.swift
//  NeuraLink
//
//  Speaks a past assistant message aloud from the chat-history transcript,
//  mirroring the voice-preview path in PersonaSettingsView: the engine follows
//  the CURRENT mode, so playback always works regardless of which model
//  produced the message.
//
//    - OpenAI mode  -> /v1/audio/speech with the current character's persona
//                      voice, played via AVAudioPlayer (VoicePreviewPlayer).
//    - Local mode   -> TTSEngineSelector's engine for the current character
//                      (VoiceVox for the Japanese model, else OpenVoice with a
//                      System-TTS fallback), streamed via LocalTTSPreviewPlayer.
//
//  One message plays at a time; starting another stops the current one.
//
//  Created by Dedicatus on 16/07/2026.
//

import Foundation
import Observation

@Observable
@MainActor
final class TranscriptSpeechPlayer {

    enum Phase {
        case idle
        case loading
        case playing
    }

    /// Message currently being synthesized/spoken. Stays set (stale, harmless)
    /// after natural playback end — `phase(for:)` resolves to `.idle` then.
    private(set) var speakingMessageID: Int64?

    private let cloudPlayer = VoicePreviewPlayer()
    private let localPlayer = LocalTTSPreviewPlayer()
    /// True from start until the synthesis task finishes (success or failure).
    /// Distinguishes "fetching/synthesizing" from "audio draining" and from
    /// a failed fetch that never produced audio.
    private var isWorking = false
    private var speakTask: Task<Void, Never>?
    /// Engine currently synthesizing, so `stop()` can abort the synthesis
    /// itself — cancelling the Task alone wouldn't interrupt `engine.speak`.
    private var activeEngine: (any TTSEngineProtocol)?

    private var isLocalMode: Bool { OpenAISettings.shared.isLocalLLMEnabled }

    /// The character whose voice is used — whichever avatar is currently
    /// loaded in the live scene.
    private var currentCharacter: String {
        let name = RealtimeChatState.shared.selectedCharacterName
        if !name.isEmpty { return name }
        return VRMModelRegistry.defaultModel?.name ?? "Ekaterina"
    }

    /// Local engines always produce audio (System TTS is the selector's last
    /// resort); OpenAI playback needs the API enabled with a valid key.
    var isAvailable: Bool {
        if isLocalMode { return true }
        let settings = OpenAISettings.shared
        return settings.isEnabled && settings.hasValidKey
    }

    func phase(for messageID: Int64) -> Phase {
        guard speakingMessageID == messageID else { return .idle }
        if cloudPlayer.isSpeaking || localPlayer.isSpeaking { return .playing }
        return isWorking ? .loading : .idle
    }

    /// Play the message, or stop it if it's the one already active.
    func toggle(_ message: ConversationMessage) {
        if phase(for: message.id) != .idle {
            stop()
            return
        }
        // Capture before stop() nils it — the new run must await the old one.
        let previousTask = speakTask
        stop()

        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        speakingMessageID = message.id
        isWorking = true
        let local = isLocalMode
        // Await the previous run before starting: its callback-restore (the
        // `defer` in speakLocal) must land first, or this run would capture
        // the transcript player as the engine's "previous" chat callback.
        // stop() aborted that run's synthesis, so the wait is brief.
        speakTask = Task { [weak self, previousTask] in
            _ = await previousTask?.value
            guard let self, !Task.isCancelled else { return }
            if local {
                await self.speakLocal(text)
            } else {
                await self.speakOpenAI(text)
            }
            self.isWorking = false
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        // Aborting the engine's synthesis makes an in-flight `speak` return
        // promptly, which also releases the serialized next run (see toggle).
        activeEngine?.stop()
        activeEngine = nil
        cloudPlayer.stop()
        localPlayer.stop()
        speakingMessageID = nil
        isWorking = false
    }

    // MARK: - OpenAI path

    private func speakOpenAI(_ text: String) async {
        let settings = OpenAISettings.shared
        guard settings.isEnabled && settings.hasValidKey else { return }
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else { return }

        let voice = CharacterPersona.forCharacter(named: currentCharacter).voice
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": voice
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                nlLog(
                    "[TranscriptSpeech] OpenAI TTS failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)",
                    level: .error)
                return
            }
            guard !Task.isCancelled else { return }
            cloudPlayer.start(data: data)
        } catch {
            nlLog("[TranscriptSpeech] OpenAI TTS request failed: \(error)", level: .error)
        }
    }

    // MARK: - Local path

    /// Synthesizes through whatever engine the selector resolves for the
    /// current character — the same engine a live chat turn would use. The
    /// engine's chat callback is saved and restored so a later live turn's
    /// PCM buffers aren't routed to the transcript player.
    private func speakLocal(_ text: String) async {
        let character = currentCharacter
        guard let engine = TTSEngineSelector.shared.engine(for: character) else {
            nlLog("[TranscriptSpeech] No TTS engine resolved for '\(character)'", level: .error)
            return
        }

        let previousCallback = engine.onBufferReady
        engine.onBufferReady = { [weak localPlayer] buffer in
            DispatchQueue.main.async { localPlayer?.schedule(buffer) }
        }
        activeEngine = engine
        defer {
            engine.onBufferReady = previousCallback
            activeEngine = nil
        }

        do {
            try await engine.initialize()
            guard !Task.isCancelled else { return }
            try await engine.speak(text, persona: character)
        } catch {
            nlLog("[TranscriptSpeech] Local TTS playback failed: \(error)", level: .error)
        }
    }
}
