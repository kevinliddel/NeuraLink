//
//  LocalLLMManager+TTS.swift
//  NeuraLink
//
//  TTS helpers split out to keep LocalLLMManager.swift.
//  - localLLMSystemPrompt: minimal spoken-word prompts for local 1–2B models
//  - bestAvailableVoice:   voice picker that searches installed voices by name/pattern
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

    /// Picks the best installed voice for a character by searching `speechVoices()` by name
    /// pattern and quality tier, rather than relying on a hardcoded identifier string.
    /// `AVSpeechSynthesisVoice(identifier:)` silently returns nil when the voice isn't
    /// downloaded, which causes every call to fall through to the same generic system default.
    func bestAvailableVoice(for characterName: String) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()

        if !voicesLogged {
            voicesLogged = true
            print("[TTS] Installed voices (\(all.count)):")
            for v in all.sorted(by: { $0.language < $1.language }) {
                print("  [\(v.language) q=\(v.quality.rawValue)] \(v.name) — \(v.identifier)")
            }
        }

        let useJapanese = LocalModelDownloadManager.shared.selectedConfig == .japaneseLlama1b

        switch characterName.lowercased() {
        case "ekaterina":
            if useJapanese {
                return all.first { $0.name == "Kyoko" }
                    ?? all.first { $0.identifier.contains("Kyoko") }
                    ?? all.filter { $0.language.hasPrefix("ja-JP") }.max { $0.quality.rawValue < $1.quality.rawValue }
                    ?? AVSpeechSynthesisVoice(language: "ja-JP")
            }
            return all.first { $0.name == "Ava" }
                ?? all.first { $0.identifier.contains("Ava") }
                ?? all.filter { $0.language.hasPrefix("en-US") }.max { $0.quality.rawValue < $1.quality.rawValue }
                ?? AVSpeechSynthesisVoice(language: "en-US")
        case "sonya":
            if useJapanese {
                return all.first { $0.name == "O-ren" }
                    ?? all.first { $0.identifier.contains("O-ren") }
                    ?? all.filter { $0.language.hasPrefix("ja-JP") }.max { $0.quality.rawValue < $1.quality.rawValue }
                    ?? AVSpeechSynthesisVoice(language: "ja-JP")
            }
            return all.first { $0.name == "Joelle" }
                ?? all.first { $0.identifier.contains("Joelle") }
                ?? all.filter { $0.language.hasPrefix("en-US") }.max { $0.quality.rawValue < $1.quality.rawValue }
                ?? AVSpeechSynthesisVoice(language: "en-US")
        default:
            if useJapanese {
                return all.filter { $0.language.hasPrefix("ja-JP") }.max { $0.quality.rawValue < $1.quality.rawValue }
                    ?? AVSpeechSynthesisVoice(language: "ja-JP")
            }
            return all.filter { $0.language.hasPrefix("en-US") }.max { $0.quality.rawValue < $1.quality.rawValue }
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
    }

    /// Generates audio from text using AVSpeechSynthesizer and schedules it on the AVAudioEngine.
    func speakChunk(_ text: String) {
        if !firstAudioLatencyLogged,
            let start = turnStartNs,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstAudioLatencyLogged = true
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("[LocalLLM] First TTS chunk latency: \(String(format: "%.1f", elapsedMs)) ms")
        }
        
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.replacingOccurrences(of: #"\*[^*\n]+\*"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\[[^\]\n]+\]"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty,
              clean.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
        else { return }

        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = bestAvailableVoice(for: state.selectedCharacterName)

        if clean.hasSuffix("?") || clean.hasSuffix("？") {
            utterance.pitchMultiplier = 1.1
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        } else if clean.hasSuffix("!") || clean.hasSuffix("！") {
            utterance.pitchMultiplier = 1.05
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate + 0.03
        } else {
            utterance.pitchMultiplier = 1.0
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        }

        synthesizer.write(utterance) { [weak self] (buffer: AVAudioBuffer) in
            guard let self = self, let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            guard pcmBuffer.frameLength > 0 else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let currentFormat = self.playerNode.outputFormat(forBus: 0)
                if currentFormat != pcmBuffer.format {
                    let wasRunning = self.audioEngine.isRunning
                    if wasRunning { self.audioEngine.pause() }

                    self.audioEngine.disconnectNodeInput(self.playerNode)
                    self.audioEngine.connect(
                        self.playerNode, to: self.audioEngine.mainMixerNode, format: pcmBuffer.format)

                    if wasRunning { try? self.audioEngine.start() }
                }

                if !self.audioEngine.isRunning { try? self.audioEngine.start() }
                if !self.playerNode.isPlaying { self.playerNode.play() }

                self.pendingTTSBuffers += 1
                self.playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataConsumed) {
                    [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.pendingTTSBuffers -= 1
                        if self.pendingTTSBuffers == 0 && self.ttsGenerationDone {
                            self.ttsGenerationDone = false
                            self.state.status = .ready
                        }
                    }
                }
            }
        }
    }
}
