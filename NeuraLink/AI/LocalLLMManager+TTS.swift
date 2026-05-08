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
}
