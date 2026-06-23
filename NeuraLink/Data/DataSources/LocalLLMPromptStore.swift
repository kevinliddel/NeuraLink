//
//  LocalLLMPromptStore.swift
//  NeuraLink
//
//  Persists user-edited system prompts for local LLM characters.
//  Separate from PersonaStore which holds the OpenAI persona instructions/voice.
//
//  Storage is the `character_ai` SQL table (MemoryStore+Personas.swift), keyed
//  by (character, engine) where engine is "gemma_jp" for the Japanese tier and
//  "local" for every other local model. Thin facade — no in-memory cache.
//
//  Created by Dedicatus on 30/04/2026.
//

import Foundation

@MainActor
final class LocalLLMPromptStore {
    static let shared = LocalLLMPromptStore()

    private init() {}

    /// Maps the model config to the `character_ai` engine key: the Japanese
    /// Gemma tier is its own slot; every other local model shares "local".
    private func engineKey(
        for config: LocalModelDownloadManager.ModelConfiguration?
    ) -> String {
        config == .japaneseGemma2b
            ? MemoryStore.PersonaEngine.gemmaJP
            : MemoryStore.PersonaEngine.local
    }

    // MARK: - Public API

    /// Returns the user-saved prompt for the character and model config, or the built-in default.
    func effectivePrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) -> String {
        if let stored = MemoryStore.shared.personaPrompt(
            character: characterName, engine: engineKey(for: config)) {
            return stored
        }
        return Self.defaultPrompt(for: characterName, config: config)
    }

    func savePrompt(
        _ prompt: String,
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) {
        MemoryStore.shared.setPersonaPrompt(
            character: characterName, engine: engineKey(for: config), prompt: prompt)
    }

    /// Clears the override so `effectivePrompt` reverts to the built-in default.
    func resetPrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) {
        MemoryStore.shared.setPersonaPrompt(
            character: characterName, engine: engineKey(for: config), prompt: nil)
    }

    // MARK: - Built-in defaults

    static func defaultPrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) -> String {
        if config == .japaneseGemma2b {
            return defaultJapanesePrompt(for: characterName)
        }
        return defaultEnglishPrompt(for: characterName, config: config)
    }

    private static func defaultEnglishPrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration?
    ) -> String {
        let emotionTag = "Use [emotion:seconds] tags (e.g. [happy:2], [sad:1]) in your reply. Never say the emotion name aloud.\n"

        if config == .llama1b {
            let tool = "To save a user fact output only: <tool name=\"\(AppFunctionTool.rememberFact)\">{\"subject\":\"User\",\"predicate\":\"likes\",\"object\":\"X\"}</tool>\n"
            switch characterName.lowercased() {
            case "ekaterina":
                return emotionTag + tool
                    + "I am Ekaterina, a warm big-sister. I reply in 1–2 natural spoken sentences."
            case "sonya":
                return emotionTag + tool
                    + "I am Sonya, a blunt tsundere. I reply in 1–2 sentences. I occasionally say Stupid."
            default:
                return emotionTag + tool
                    + "I reply in one short spoken sentence."
            }
        }

        let toolInstruction = """
        To save a fact about the user, output ONLY: \
        <tool name="\(AppFunctionTool.rememberFact)">{"subject":"User","predicate":"likes","object":"Sushi"}</tool> \
        No other text with the tool call.
        """
        switch characterName.lowercased() {
        case "ekaterina":
            return emotionTag + """
            You are Ekaterina, a warm big-sister type. Reply in 1–2 natural spoken sentences. \
            Be gentle, caring, and conversational. No asterisk actions, no narration, no parentheses.
            """ + "\n" + toolInstruction
        case "sonya":
            return emotionTag + """
            You are Sonya, a blunt tsundere. Reply in 1–2 sentences. Be dismissive but secretly kind. \
            Occasionally say Stupid. No asterisk actions, no narration, no parentheses.
            """ + "\n" + toolInstruction
        default:
            return emotionTag + "Reply in one short spoken sentence. Be natural and conversational.\n" + toolInstruction
        }
    }

    private static func defaultJapanesePrompt(for characterName: String) -> String {
        let emotionTag = "感情タグ[感情:秒数]（例:[happy:2],[sad:1]）を返答に自然に含めること。感情名は声に出さないこと。\n"
        let tool = "ユーザーの情報を保存する時のみ出力: <tool name=\"\(AppFunctionTool.rememberFact)\">{\"subject\":\"User\",\"predicate\":\"likes\",\"object\":\"X\"}</tool>\n"
        switch characterName.lowercased() {
        case "ekaterina":
            return emotionTag + tool
                + "私はエカテリーナ、温かく優しいお姉さん。日本語で1〜2文で話す。"
        case "sonya":
            return emotionTag + tool
                + "私はソーニャ、ツンデレ。日本語で1〜2文で話す。たまに「バカ」と言う。"
        default:
            return emotionTag + tool + "日本語で1文で話す。"
        }
    }
}
