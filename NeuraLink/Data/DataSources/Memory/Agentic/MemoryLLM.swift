//
//  MemoryLLM.swift
//  NeuraLink
//
//  Dual-engine text generator for the LLM-backed memory steps (retain
//  extraction, consolidation, mental-model refresh, reflect). Routes to the
//  one-shot Chat Completions client when OpenAI is active, otherwise to the
//  local engine's silent generation — the same split ReflectionManager and
//  ConversationTitler use. Injected as a protocol so every memory step is
//  unit-testable with a scripted stub.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

/// Which engine will answer, and therefore which prompt/parse format to use.
enum MemoryLLMTier: Sendable {
    /// Cloud chat model — JSON output is reliable.
    case cloud
    /// 1–2B local model — labeled-line output only, strict parsing gates.
    case local
    /// No engine available; only the no-LLM paths (raw retain, recall) run.
    case none
}

protocol MemoryLLM: Sendable {
    var tier: MemoryLLMTier { get }
    /// One system + user exchange → assistant text (nil on failure).
    func complete(system: String, user: String, maxTokens: Int) async -> String?
}

/// Production router. `tier` is re-evaluated per call so toggling the
/// OpenAI key or loading/unloading the local model takes effect immediately.
struct LiveMemoryLLM: MemoryLLM {

    var tier: MemoryLLMTier {
        let openAI = OpenAISettings.shared
        if openAI.isEnabled && openAI.hasValidKey { return .cloud }
        if LocalLLMManager.shared.llmEngine.isLoaded,
           LocalModelDownloadManager.shared.selectedConfig != .llmJp3 {
            return .local
        }
        return .none
    }

    func complete(system: String, user: String, maxTokens: Int) async -> String? {
        switch tier {
        case .cloud:
            return await OpenAIChatClient.complete(
                system: system, user: user, maxTokens: maxTokens, temperature: 0.2)
        case .local:
            let text = await LocalLLMManager.shared.runSilentGeneration(
                prompt: "\(system)\n\n\(user)", maxTokens: maxTokens)
            return text.isEmpty ? nil : text
        case .none:
            return nil
        }
    }
}
