//
//  LocalLLMPromptStore.swift
//  NeuraLink
//
//  Persists user-edited system prompts for local LLM characters.
//  Separate from PersonaStore which holds OpenAI persona instructions and voice names.
//
//  Belt-and-suspenders persistence: protected JSON file + UserDefaults backup.
//  See PersonaStore.swift for the rationale.
//
//  Created by Dedicatus on 30/04/2026.
//

import Foundation
import SwiftUI

@Observable
final class LocalLLMPromptStore {
    static let shared = LocalLLMPromptStore()

    private let legacyKey = "com.neuralink.local-llm-prompts.v1"
    private let backupKey = "com.neuralink.local-llm-prompts.v2.backup"

    /// Authoritative in-memory cache. Disk + UserDefaults backup are the
    /// durable layers.
    @ObservationIgnored private var saved: [String: String] = [:]

    private var fileURL: URL? {
        do {
            let dir = try ProtectedStorage.privateApplicationSupportURL()
            return dir.appendingPathComponent("local_llm_prompts.json")
        } catch {
            nlLog("[LocalLLMPromptStore] Failed to resolve secure private storage directory: \(error)", level: .error)
            return nil
        }
    }

    private init() {
        saved = loadInitialFromDisk()
        nlLog("[LocalLLMPromptStore] Initialized with \(saved.count) saved prompt(s).", level: .info)
    }

    private func loadInitialFromDisk() -> [String: String] {
        // Layer 1 — protected file.
        if let url = fileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            nlLog("[LocalLLMPromptStore] Loaded \(decoded.count) prompt(s) from \(url.path)", level: .info)
            return decoded
        }

        // Layer 2 — UserDefaults backup.
        if let backupData = UserDefaults.standard.data(forKey: backupKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: backupData) {
            nlLog("[LocalLLMPromptStore] Loaded \(decoded.count) prompt(s) from UserDefaults backup.", level: .info)
            return decoded
        }

        // Layer 3 — legacy migration.
        if let legacyData = UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: legacyData) {
            nlLog("[LocalLLMPromptStore] Loaded \(decoded.count) prompt(s) from legacy UserDefaults key.", level: .info)
            UserDefaults.standard.set(legacyData, forKey: backupKey)
            if let url = fileURL {
                _ = try? legacyData.write(to: url, options: .atomic)
                try? ProtectedStorage.protect(url)
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return decoded
        }

        nlLog("[LocalLLMPromptStore] No saved prompts found — starting fresh.", level: .info)
        return [:]
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
        let key = storeKey(for: characterName, config: config)
        var updated = saved
        updated[key] = prompt
        saved = updated
        nlLog("[LocalLLMPromptStore] Saving prompt for '\(key)' (length=\(prompt.count))", level: .info)
        flushToBothLayers()
    }

    func resetPrompt(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration? = nil
    ) {
        let key = storeKey(for: characterName, config: config)
        var updated = saved
        updated.removeValue(forKey: key)
        saved = updated
        nlLog("[LocalLLMPromptStore] Reset prompt for '\(key)'", level: .info)
        flushToBothLayers()
    }

    // MARK: - Internals

    private func storeKey(
        for characterName: String,
        config: LocalModelDownloadManager.ModelConfiguration?
    ) -> String {
        let base = characterName.lowercased()
        return config == .japaneseLlama1b ? "\(base)_jp" : base
    }

    private func flushToBothLayers() {
        guard let encoded = try? JSONEncoder().encode(saved) else {
            nlLog("[LocalLLMPromptStore] flushToBothLayers: failed to encode \(saved.count) prompt(s).", level: .error)
            return
        }
        if let url = fileURL {
            do {
                try encoded.write(to: url, options: .atomic)
                try? ProtectedStorage.protect(url)
                nlLog("[LocalLLMPromptStore] flushToBothLayers: wrote \(encoded.count) bytes to \(url.lastPathComponent)", level: .info)
            } catch {
                nlLog("[LocalLLMPromptStore] flushToBothLayers: file write failed: \(error)", level: .error)
            }
        } else {
            nlLog("[LocalLLMPromptStore] flushToBothLayers: no fileURL — file layer skipped.", level: .error)
        }
        UserDefaults.standard.set(encoded, forKey: backupKey)
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
        let emotionTag = "Use [emotion:seconds] tags (e.g. [happy:2], [sad:1]) in your reply. Never say the emotion name aloud.\n"

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
