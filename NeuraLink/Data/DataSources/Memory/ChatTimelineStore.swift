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
        // After a completed turn, let the active AI name the chat (≥5 messages).
        if let id = ConversationStore.shared.activeConversationID {
            ConversationTitler.shared.maybeAutoTitle(conversationID: id)
        }
        // Agentic memory: extract facts once enough new turns accumulated.
        MemoryRetain.shared.maybeRetain()
        pruneIfNeeded()
        CompanionStateStore.shared.refresh()
    }

    /// Tools whose result is the companion's own bookkeeping rather than
    /// anything it said. Recalling a memory or filing one away is thinking,
    /// not conversation, and the raw text of it turning up in the history
    /// reads like the model talking to itself.
    private static let silentTools: Set<String> = [
        AppFunctionTool.searchMemory, AppFunctionTool.rememberFact
    ]

    /// Opening lines of the tool results that used to reach the transcript,
    /// so histories written before they were silenced can be cleaned once.
    private static let silentToolPrefixes = [
        "Memory search results", "Got it! I'll always remember"
    ]

    /// Clears those rows from stored conversations. Cheap and idempotent —
    /// after the first pass it matches nothing.
    static func purgeSilentToolMessages() {
        let removed = MemoryStore.shared.deleteToolMessages(startingWith: silentToolPrefixes)
        if removed > 0 {
            nlLog("[ChatTimeline] removed \(removed) recall/remember rows from history", level: .info)
            CompanionStateStore.shared.refresh()
        }
    }

    /// True for tools whose result is the companion's own bookkeeping.
    static func isSilentTool(_ name: String) -> Bool { silentTools.contains(name) }

    static func logToolCall(name: String, result: String) {
        guard !isSilentTool(name) else { return }
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
