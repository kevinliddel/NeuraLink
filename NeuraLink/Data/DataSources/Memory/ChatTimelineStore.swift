//
//  ChatTimelineStore.swift
//  NeuraLink
//
//  Lightweight wrapper for chat timeline writes that should not block UI/audio threads.
//

import Foundation

enum ChatTimelineStore {
    static func logUserMessage(_ text: String) {
        guard MemorySettings.shared.isEnabled else { return }
        MemoryStore.shared.insertChatEvent(role: "user", kind: "message", title: "You", detail: text)
        pruneIfNeeded()
        CompanionStateStore.shared.refresh()
    }

    static func logAIMessage(_ text: String) {
        guard MemorySettings.shared.isEnabled else { return }
        guard MemorySettings.shared.storeAIResponses else { return }
        MemoryStore.shared.insertChatEvent(role: "ai", kind: "message", title: "AI", detail: text)
        pruneIfNeeded()
        CompanionStateStore.shared.refresh()
    }

    static func logToolCall(name: String, result: String) {
        guard MemorySettings.shared.isEnabled else { return }
        let title = "Tool: \(name)"
        MemoryStore.shared.insertChatEvent(role: "tool", kind: "tool_call", title: title, detail: result)
        pruneIfNeeded()
        CompanionStateStore.shared.refresh()
    }

    private static func pruneIfNeeded() {
        let days = MemorySettings.shared.autoForgetDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400.0)
        MemoryStore.shared.pruneChatEvents(olderThan: cutoff)
    }
}
