//
//  ChatTimelineStore.swift
//  NeuraLink
//
//  Write seam for chat history, shared by both engines (local LLM via
//  LocalLLMManager+Engine, OpenAI via OpenAIRealtimeManager+Handlers).
//  Appends each turn to the ACTIVE conversation via ConversationStore.
//
//  Chat history is a core feature, so it persists regardless of the
//  memory/RAG toggle (`MemorySettings.isEnabled`). That toggle still gates
//  the separate long-term-memory paths (RAGManager embeddings + fact
//  extraction), which are wired at their own call sites.
//

import Foundation

enum ChatTimelineStore {
    static func logUserMessage(_ text: String) {
        // Never persist empty/whitespace-only user turns (e.g. a blank
        // transcription) — keeps the history clean.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ConversationStore.shared.appendMessage(role: "user", kind: "message", content: text)
        pruneIfNeeded()
        CompanionStateStore.shared.refresh()
    }

    static func logAIMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ConversationStore.shared.appendMessage(role: "assistant", kind: "message", content: text)
        pruneIfNeeded()
        CompanionStateStore.shared.refresh()
    }

    static func logToolCall(name: String, result: String) {
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ConversationStore.shared.appendMessage(role: "tool", kind: "tool_call", content: result)
        pruneIfNeeded()
        CompanionStateStore.shared.refresh()
    }

    private static func pruneIfNeeded() {
        let days = MemorySettings.shared.autoForgetDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400.0)
        MemoryStore.shared.pruneConversations(olderThan: cutoff)
    }
}
