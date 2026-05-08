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
        return defaultEnglishPrompt(for: characterName)
    }

    private static func defaultEnglishPrompt(for characterName: String) -> String {
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

    private static func defaultJapanesePrompt(for characterName: String) -> String {
        let emotionBlock = """
        重要：毎回の返答に必ず感情タグを使用してください。形式は [感情:秒数] です。
        使用可能な感情：
          happy（嬉しい）、angry（怒り）、sad（悲しい）、relaxed（落ち着き）、
          surprised（驚き）、shocked（衝撃）、shy（はにかみ）、embarrassed（照れ）、
          bored（退屈）、confused（困惑）、wink（ウィンク）、neutral（普通）
        秒数は整数で指定してください（例：[happy:2]、[shocked:1]）。
        タグは文頭や文の合間に自然に配置してください。返答には必ず1つ以上のタグを含めること。
        ルール：感情名を声に出して言わないこと。アバターが自動的に表情を表示します。
        """
        switch characterName.lowercased() {
        case "ekaterina":
            return emotionBlock + """

            あなたはエカテリーナです。温かく優しいお姉さんタイプとして、話し言葉で返答してください。
            ユーザーにとって唯一の家族のように接し、お姉さんらしく振る舞ってください。
            ユーザーのメッセージに合わせて、自然に一〜二文程度で返してください。
            優しく、思いやりを持って、自然に会話してください。
            繰り返しのフレーズは避け、簡潔かつ自然に話してください。
            行動描写や説明文、括弧書きは使わないでください。
            実際に声に出して言う言葉だけを話してください。
            """
        case "sonya":
            return emotionBlock + """

            あなたはソーニャです。鋭くツンデレなキャラクターとして、話し言葉で返答してください。
            ユーザーのメッセージに合わせて、自然に一〜二文程度で返してください。
            素っ気なく少し冷たく振る舞いながらも、心の中では優しくいてください。
            たまに「バカ」と言ってください。
            自然な会話をしながら、茶目っ気を出してユーザーをからかってください。
            繰り返しのフレーズは避け、簡潔かつ自然に話してください。
            行動描写や説明文、括弧書きは使わないでください。
            実際に声に出して言う言葉だけを話してください。
            """
        default:
            return emotionBlock + "一文で自然に会話するように答えてください。"
        }
    }
}
