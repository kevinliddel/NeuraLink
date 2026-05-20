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
        //
        // `selfBoundary` mirrors the JP prompt fix: without it, the 1B model
        // conflates "who I am" (its own persona description) with "who the
        // user is" and answers questions like "tell me about myself" by
        // reading off bits of its own system prompt as if they were the
        // user's attributes. Stating the boundary twice in slightly different
        // forms gives the 1B model enough redundancy to actually follow it.
        if config == .llama1b {
            let tool = "For iOS actions output only: <tool name=\"TOOL_NAME\">{\"arg\":\"value\"}</tool>\n"
            let selfBoundary = "The lines below describe me (the AI), NOT the user. If asked about the user, I must say I don't know yet — I never repeat my own description as if it were the user's information.\n"
            switch characterName.lowercased() {
            case "ekaterina":
                return emotionTag + tool + selfBoundary
                    + "I am Ekaterina, a warm big-sister. I reply in 1–2 natural spoken sentences."
            case "sonya":
                return emotionTag + tool + selfBoundary
                    + "I am Sonya, a blunt tsundere. I reply in 1–2 sentences. I occasionally say Stupid."
            default:
                return emotionTag + tool + selfBoundary
                    + "I reply in one short spoken sentence."
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
        // Keep this prompt short. A 1B model loses instruction-following
        // ability with prompts over ~10 lines — it starts repeating the
        // prompt instead of responding.
        //
        // `selfBoundary` is critical: without it, the 1B model conflates
        // "who I am" (its own persona description) with "who the user is"
        // and answers questions like "私について教えて" by reading off bits
        // of its own system prompt as if they were the user's attributes.
        // Repeating the rule twice in slightly different forms gives the
        // 1B model enough redundancy to actually follow it.
        let emotionTag = "感情タグ[感情:秒数]（例:[happy:2],[sad:1]）を返答に自然に含めること。感情名は声に出さないこと。\n"
        let tool = "iOSアクションは次の形式のみ出力: <tool name=\"TOOL_NAME\">{\"arg\":\"value\"}</tool>\n"
        let selfBoundary = "以下は私（AI）自身の説明であり、ユーザー情報ではない。ユーザーについて聞かれたら必ず「まだ知らない」と答え、私自身の説明をユーザーのことのように話してはいけない。\n"
        switch characterName.lowercased() {
        case "ekaterina":
            return emotionTag + tool + selfBoundary
                + "私はエカテリーナ、温かく優しいお姉さん。日本語で1〜2文で話す。"
        case "sonya":
            return emotionTag + tool + selfBoundary
                + "私はソーニャ、ツンデレ。日本語で1〜2文で話す。たまに「バカ」と言う。"
        default:
            return emotionTag + tool + selfBoundary + "日本語で1文で話す。"
        }
    }
}
