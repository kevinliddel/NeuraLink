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
import SwiftUI

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

    // MARK: - Public API

    /// Returns the user-saved prompt for the character and model config, or the built-in default.
    func effectivePrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) -> String {
        let k = storeKey(for: characterName, config: config)
        return saved[k] ?? Self.defaultPrompt(for: characterName, config: config)
    }

    func savePrompt(
        _ prompt: String,
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) {
        saved[storeKey(for: characterName, config: config)] = prompt
        persist()
    }

    func resetPrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) {
        saved.removeValue(forKey: storeKey(for: characterName, config: config))
        persist()
    }

    // MARK: - Internals

    private func storeKey(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration?
    ) -> String {
        let base = characterName.lowercased()
        return config == .japaneseLlama1b ? "\(base)_jp" : base
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Built-in defaults

    static func defaultPrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) -> String {
        if config == .japaneseLlama1b {
            return defaultJapanesePrompt(for: characterName)
        }
        return defaultEnglishPrompt(for: characterName, config: config)
    }

    private static func defaultEnglishPrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration?
    ) -> String {
        // CharacterPersona.emotionInstructions uses set_emotion() function-call syntax
        // designed for the OpenAI realtime path. Local models use [emotion:duration] text
        // tags parsed by parseAndTriggerEmotion — so we define the format inline here.
        let emotionTag = "Use [emotion:seconds] tags (e.g. [happy:2], [sad:1]) in your reply. Never say the emotion name aloud.\n"

        // Llama 1B has the same 1B attention budget as the Japanese model — keep the
        // prompt to ~3 lines so it doesn't crowd out the user message.
        if config == .llama1b {
            let tool = "For iOS actions output only: <tool name=\"TOOL_NAME\">{\"arg\":\"value\"}</tool>\n"
            switch characterName.lowercased() {
            case "ekaterina":
                return emotionTag + tool + "You are Ekaterina, a warm big-sister. Reply in 1–2 natural spoken sentences. You don't know personal details about the user unless they tell you."
            case "sonya":
                return emotionTag + tool + "You are Sonya, a blunt tsundere. Reply in 1–2 sentences. Occasionally say Stupid. You don't know personal details about the user unless they tell you."
            default:
                return emotionTag + tool + "Reply in one short spoken sentence."
            }
        }

        // Qwen 2B can handle a richer prompt — still trimmed vs the original ~20-line version.
        let toolInstruction = """
        For iOS actions (reminders, notes, apps), output ONLY: <tool name="TOOL_NAME">{"arg":"value"}</tool>
        Tools: \(AppFunctionTool.getWeather), \(AppFunctionTool.searchWeb), \(AppFunctionTool.playMusic), \
        \(AppFunctionTool.createReminder), \(AppFunctionTool.createNote), \(AppFunctionTool.openApp), \
        \(AppFunctionTool.analyzeCamera), \(AppFunctionTool.rememberFact), \(AppFunctionTool.poseForPhoto). \
        No other text with the tool call.
        """
        switch characterName.lowercased() {
        case "ekaterina":
            return emotionTag + """
            You are Ekaterina, a warm big-sister type. Reply in 1–2 natural spoken sentences. \
            Be gentle, caring, and conversational. No asterisk actions, no narration, no parentheses. \
            You don't know personal details about the user unless they tell you.
            """ + "\n" + toolInstruction
        case "sonya":
            return emotionTag + """
            You are Sonya, a blunt tsundere. Reply in 1–2 sentences. Be dismissive but secretly kind. \
            Occasionally say Stupid. No asterisk actions, no narration, no parentheses. \
            You don't know personal details about the user unless they tell you.
            """ + "\n" + toolInstruction
        default:
            return emotionTag + "Reply in one short spoken sentence. Be natural and conversational.\n" + toolInstruction
        }
    }

    private static func defaultJapanesePrompt(for characterName: String) -> String {
        // Keep this prompt short. A 1B model loses instruction-following ability
        // with prompts over ~10 lines — it starts repeating the prompt instead of responding.
        let emotionTag = "感情タグ[感情:秒数]（例:[happy:2],[sad:1]）を返答に自然に含めること。感情名は声に出さないこと。\n"
        let tool = "iOSアクションは次の形式のみ出力: <tool name=\"TOOL_NAME\">{\"arg\":\"value\"}</tool>\n"
        switch characterName.lowercased() {
        case "ekaterina":
            return emotionTag + tool + "私はエカテリーナ、温かく優しいお姉さん。日本語で1〜2文で話す。ユーザーのことを聞かれたら「まだ知らない」と答える。"
        case "sonya":
            return emotionTag + tool + "私はソーニャ、ツンデレ。日本語で1〜2文で話す。たまに「バカ」と言う。ユーザーのことを聞かれたら「知らない」と答える。"
        default:
            return emotionTag + tool + "日本語で1文で話す。"
        }
    }
}
