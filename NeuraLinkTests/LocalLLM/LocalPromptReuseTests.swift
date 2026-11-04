//
//  LocalPromptReuseTests.swift
//  NeuraLinkTests
//
//  How much of each local-LLM prompt has to be prefilled from scratch. The
//  bridge reuses the KV cache up to the first token where the new prompt
//  differs from what it already holds, so a turn only pays for its suffix —
//  unless the prompt shifts near the top. Simulates a long English
//  conversation through the real LocalLLMMemoryHierarchy and measures, per
//  turn, the share of the prompt that survives (a) from the voice-start
//  warm-up and (b) from the previous turn plus its reply.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Testing
@testable import NeuraLink

@Suite("Local prompt prefix reuse", .serialized)
struct LocalPromptReuseTests {

    struct TurnReuse {
        let turn: Int
        let promptTokens: Int
        let fromWarmup: Int   // tokens the warm-up already holds
        let fromPrevious: Int // tokens the previous turn already holds
        var freshTokens: Int { promptTokens - max(fromWarmup, fromPrevious) }
    }

    /// Llama-3 rendering, as the GGUF template and the bridge see it.
    static func render(_ messages: [LLMChatMessage], generationPrompt: Bool) -> String {
        var s = ""
        for m in messages { s += "<|start_header_id|>\(m.role)<|end_header_id|>\n\n\(m.content)<|eot_id|>" }
        if generationPrompt { s += "<|start_header_id|>assistant<|end_header_id|>\n\n" }
        return s
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a.utf8, b.utf8) {
            guard x == y else { break }
            n += 1
        }
        return n
    }

    static func tokens(_ bytes: Int) -> Int { Int((Double(bytes) / LocalLLMContextBudget.bytesPerToken).rounded()) }

    /// Plays `turns` user/assistant exchanges into a fresh conversation the
    /// way the app does (warm-up before the user message is logged, the turn
    /// after) and returns the reuse per turn.
    @MainActor
    static func simulate(turns: Int) async -> [TurnReuse] {
        let store = ConversationStore.shared
        store.startNewChat()
        defer {
            if let id = store.activeConversationID { store.deleteConversation(id: id) }
        }
        let hierarchy = LocalLLMMemoryHierarchy.shared
        let character = "Ekaterina"
        let base = LocalLLMPromptStore.defaultPrompt(for: character, config: .llama1b)
        var previousKV = ""
        var results: [TurnReuse] = []
        for turn in 1...turns {
            let text = "Turn \(turn): I spent the afternoon fixing my bike and then cooked pasta for my sister."
            let warm = await hierarchy.buildPrefillMessages(config: .llama1b, characterName: character, baseSystemPrompt: base)
            let warmPrompt = render(warm, generationPrompt: false)
            store.appendMessage(role: "user", kind: "message", content: text)
            let messages = await hierarchy.buildMessages(
                userInput: text, config: .llama1b, characterName: character, baseSystemPrompt: base)
            let prompt = render(messages, generationPrompt: true)
            results.append(TurnReuse(
                turn: turn, promptTokens: tokens(prompt.utf8.count),
                fromWarmup: tokens(commonPrefix(warmPrompt, prompt)),
                fromPrevious: tokens(commonPrefix(previousKV, prompt))))
            let reply = "[happy:2] That sounds lovely! Bikes and pasta make a good day. What sauce did you make for her?"
            store.appendMessage(role: "assistant", kind: "message", content: reply)
            previousKV = prompt + reply
        }
        return results
    }

    @Test("Report prefix reuse over a long conversation when NL_LLM_DIAG_DIR is set")
    @MainActor
    func report() async throws {
        guard let out = ProcessInfo.processInfo.environment["NL_LLM_DIAG_DIR"], !out.isEmpty else { return }
        let rows = await Self.simulate(turns: 20)
        var text = "turn\tprompt_tok\tfrom_warmup\tfrom_previous\tfresh_tok\n"
        for r in rows { text += "\(r.turn)\t\(r.promptTokens)\t\(r.fromWarmup)\t\(r.fromPrevious)\t\(r.freshTokens)\n" }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("prompt_reuse.tsv"), atomically: true, encoding: .utf8)
    }
}
