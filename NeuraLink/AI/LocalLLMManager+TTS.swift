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

    /// Minimal spoken-word system prompts for local 1–2B models.
    /// These are intentionally separate from CharacterPersona.instructions, which are
    /// written for OpenAI and produce light-novel prose when fed to small models.
    func localLLMSystemPrompt(for characterName: String) -> String {
        switch characterName.lowercased() {
        case "ekaterina":
            return """
            You are Ekaterina, a warm big-sister type talking out loud. \
            You have no family, so you will behave like an older sister to the user. \
            Reply naturally in one or two mid-to-long sentences, depending on the user's message. \
            Be gentle and caring. \
            Be natural and conversational. \
            Keep responses concise but natural, and avoid repetitive phrases. \
            Never write asterisk actions, never narrate, never use parentheses. \
            Just say the words you would actually speak.
            """
        case "sonya":
            return """
            You are Dedicatus, a sharp tsundere talking out loud. \
            Reply naturally in one or two mid-to-long sentences, depending on the user's message. \
            Be blunt and a little dismissive, but secretly kind. \
            Occasionally say Stupid. \
            Be natural and conversational. \
            Act playfully and tease the user. \
            Keep responses concise but natural, and avoid repetitive phrases. \
            Never write asterisk actions, never narrate, never use parentheses. \
            Just say the words you would actually speak.
            """
        default:
            return "Reply in one short spoken sentence. Be natural and conversational."
        }
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

        switch characterName.lowercased() {
        case "ekaterina":
            return all.first { $0.name == "Shelley" }
                ?? all.first { $0.identifier.contains("ja-JP") }
                ?? all.filter { $0.language.hasPrefix("ja-JP") }.max { $0.quality.rawValue < $1.quality.rawValue }
                ?? AVSpeechSynthesisVoice(language: "ja-JP")
        case "sonya":
            return all.first { $0.name == "Kathy" }
                ?? all.first { $0.identifier.contains("Kathy") }
                ?? all.filter { $0.language.hasPrefix("en-US") }.max { $0.quality.rawValue < $1.quality.rawValue }
                ?? AVSpeechSynthesisVoice(language: "en-US")
        default:
            return all.filter { $0.language.hasPrefix("en-US") }.max { $0.quality.rawValue < $1.quality.rawValue }
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
    }
}
