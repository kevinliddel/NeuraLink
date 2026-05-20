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
        //
        // Role-boundary text ("AI vs user", "use [User Information] block")
        // lives in `LocalLLMMemoryHierarchy.buildEnglishRoleClarification`
        // rather than here — that layer knows whether the user has set a
        // display name and can mirror the JP-side fix consistently. Inline
        // "you don't know personal details" / "I must say I don't know yet"
        // text previously contradicted the [User Information] block that
        // `UserSettings.systemPromptContext` appends right after.
        let emotionTag = "Use [emotion:seconds] tags (e.g. [happy:2], [sad:1]) in your reply. Never say the emotion name aloud.\n"

        // Llama 1B: same attention budget as the Japanese model — keep
        // the persona to ~2 lines so it doesn't crowd out the user message.
        if config == .llama1b {
            let tool = "For iOS actions output only: <tool name=\"TOOL_NAME\">{\"arg\":\"value\"}</tool>\n"
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

        // Qwen tiers can handle a richer prompt. Persona stays in
        // second-person ("You are X") to match how Qwen-Instruct was
        // trained — the role-clarification block in
        // LocalLLMMemoryHierarchy uses third-person framing that doesn't
        // conflict with either voice.
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
        // Keep this prompt short. A 1B model loses instruction-following
        // ability with prompts over ~10 lines — it starts repeating the
        // prompt instead of responding.
        //
        // Role disambiguation ("私" = AI, "あなた" = user) lives in
        // `LocalLLMMemoryHierarchy.buildJPRoleClarification` rather than
        // here — that layer knows the user's display name and can name
        // both sides of the conversation explicitly. The previous static
        // `selfBoundary` text told the model to *always* say "I don't
        // know yet" when asked about the user, which contradicted the
        // adjacent "ユーザーの名前は{name}" context line and left the 1B
        // genuinely confused about whose name was whose.
        let emotionTag = "感情タグ[感情:秒数]（例:[happy:2],[sad:1]）を返答に自然に含めること。感情名は声に出さないこと。\n"
        let tool = "iOSアクションは次の形式のみ出力: <tool name=\"TOOL_NAME\">{\"arg\":\"value\"}</tool>\n"
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
