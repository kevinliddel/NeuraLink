//
//  LocalLLMManager+TTS.swift
//  NeuraLink
//
//  Routes LLM output to whichever engine `TTSEngineSelector` resolves for the
//  active persona + device tier. Owns no synthesis logic itself — it just
//  cleans the LLM's text, hands it to the engine, and pumps the engine's
//  PCM buffers into the shared AVAudioEngine / playerNode for playback.
//
//  Phase 5 wiring per docs/local_llm_tts_plan.md §3.1.
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

        let currentFormat = playerNode.outputFormat(forBus: 0)
        if currentFormat != pcmBuffer.format {
            let wasRunning = audioEngine.isRunning
            if wasRunning { audioEngine.pause() }
            audioEngine.disconnectNodeInput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: pcmBuffer.format)
            if wasRunning { try? audioEngine.start() }
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
