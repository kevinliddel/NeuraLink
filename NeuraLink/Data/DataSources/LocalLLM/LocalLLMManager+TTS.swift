//
//  LocalLLMManager+TTS.swift
//  NeuraLink
//
//  Routes LLM output to whichever engine `TTSEngineSelector` resolves for the
//  active persona + device tier. Owns no synthesis logic itself — it just
//  cleans the LLM's text, hands it to the engine, and pumps the engine's
//  PCM buffers into the shared AVAudioEngine / playerNode for playback.
//
//  Created by Dedicatus on 30/04/2026.
//

import AVFoundation

extension LocalLLMManager {

    /// Returns the active local LLM system prompt for the character —
    /// user-saved override if one exists, otherwise the built-in default.
    func localLLMSystemPrompt(for characterName: String) -> String {
        let config = LocalModelDownloadManager.shared.selectedConfig
        return LocalLLMPromptStore.shared.effectivePrompt(for: characterName, config: config)
    }

    /// Synthesises `text` and schedules the resulting audio on the player node.
    /// Dispatches engine work in a Task — speakChunk itself returns immediately,
    /// matching the fire-and-forget callsites in LocalLLMManager+Engine.
    func speakChunk(_ text: String) {
        if !firstAudioLatencyLogged,
            let start = turnStartNs,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstAudioLatencyLogged = true
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            nlLog("[LocalLLM] First TTS chunk latency: \(String(format: "%.1f", elapsedMs)) ms", level: .info)
        }

        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.replacingOccurrences(of: #"\*[^*\n]+\*"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\[[^\]\n]+\]"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(
            of: #"<tool[^>]*>[\s\S]*?<\/tool>"#,
            with: "",
            options: .regularExpression
        )
        clean = clean.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty,
              clean.unicodeScalars.contains(where: {
                  CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
              })
        else { return }

        let persona: PersonaIdentifier = state.selectedCharacterName
        let textToSpeak = clean

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let engine = TTSEngineSelector.shared.engine(for: persona) else {
                nlLog("[TTS] No engine available for persona '\(persona)'", level: .error)
                return
            }

            // Engines may emit buffers off the main actor (AVSpeechSynthesizer
            // delivers from its internal queue). Dispatch to main before
            // touching audioEngine / playerNode.
            engine.onBufferReady = { [weak self] buffer in
                DispatchQueue.main.async { self?.scheduleBuffer(buffer) }
            }

            self.inFlightSynthesis += 1
            defer { self.inFlightSynthesis -= 1 }
            do {
                try await engine.initialize()
                try await engine.speak(textToSpeak, persona: persona)
            } catch {
                nlLog("[TTS] speak failed for '\(persona)': \(error)", level: .error)
            }
        }
    }

    /// Schedules a PCM buffer on `playerNode`, reconciling format if needed.
    /// Engine-agnostic — every TTSEngineProtocol-conforming engine feeds
    /// buffers through this single path.
    func scheduleBuffer(_ pcmBuffer: AVAudioPCMBuffer) {
        guard pcmBuffer.frameLength > 0 else { return }
        // Guard the format before any connect/schedule — AVAudioEngine raises
        // an uncatchable NSException (IsFormatSampleRateAndChannelCountValid)
        // on a 0-rate / 0-channel format. Drop + log instead of crashing.
        let bufFormat = pcmBuffer.format
        guard bufFormat.sampleRate > 0, bufFormat.channelCount > 0 else {
            nlLog("[TTS] Dropping buffer — invalid format sr=\(bufFormat.sampleRate) ch=\(bufFormat.channelCount)", level: .error)
            return
        }

        let currentFormat = playerNode.outputFormat(forBus: 0)
        if currentFormat != pcmBuffer.format {
            // Only the player → ttsMixer edge is rewired (`connect` implicitly
            // breaks the prior connection); the fixed 48 kHz ttsMixer →
            // mainMixer edge keeps the downstream graph stable, so no engine
            // pause/restart — which used to interrupt mic capture — is needed.
            audioEngine.connect(playerNode, to: ttsMixerNode, format: pcmBuffer.format)
        }

        if !audioEngine.isRunning { try? audioEngine.start() }
        if !playerNode.isPlaying { playerNode.play() }

        pendingTTSBuffers += 1
        playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingTTSBuffers -= 1
                if self.pendingTTSBuffers == 0 && self.ttsGenerationDone {
                    self.ttsGenerationDone = false
                    self.state.status = .ready
                }
            }
        }
    }
}
