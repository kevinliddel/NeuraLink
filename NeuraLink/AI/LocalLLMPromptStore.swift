//
//  LocalLLMPromptStore.swift
//  NeuraLink
//
//  Persists user-edited system prompts for local LLM characters.
//  Separate from PersonaStore which holds OpenAI persona instructions and voice names.
//
//  Created by Dedicatus on 30/04/2026.
//

import Foundation

@Observable
final class LocalLLMPromptStore {
    static let shared = LocalLLMPromptStore()

    private let key = "com.neuralink.local-llm-prompts.v1"
    private var saved: [String: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            saved = decoded
        }
    }

    /// Returns the user-saved prompt for the character, or the built-in default.
    func effectivePrompt(for characterName: String) -> String {
        saved[characterName.lowercased()] ?? Self.defaultPrompt(for: characterName)
    }

    func savePrompt(_ prompt: String, for characterName: String) {
        saved[characterName.lowercased()] = prompt
        persist()
    }

    func resetPrompt(for characterName: String) {
        saved.removeValue(forKey: characterName.lowercased())
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Built-in defaults

    static func defaultPrompt(for characterName: String) -> String {
        switch characterName.lowercased() {
        case "ekaterina":
            return CharacterPersona.emotionInstructions + """
            
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
            return CharacterPersona.emotionInstructions + """
            
            You are Sonya, a sharp tsundere talking out loud. \
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
            return CharacterPersona.emotionInstructions + "Reply in one short spoken sentence. Be natural and conversational."
        }
    }
}
