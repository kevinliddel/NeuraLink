//
//  ChatSearchTests.swift
//  NeuraLinkTests
//
//  Chat history search (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C1).
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Chat history search", .serialized)
struct ChatSearchTests {

    @Test("Snippet centres on the match and marks the cuts")
    func snippet() {
        let long = String(repeating: "alpha ", count: 30) + "the Zyqx marker sits here" + String(repeating: " omega", count: 30)
        let cut = MemoryStore.snippet(long, around: "zyqx", width: 60)
        #expect(cut.hasPrefix("…"))
        #expect(cut.hasSuffix("…"))
        #expect(cut.localizedCaseInsensitiveContains("Zyqx marker"))
        #expect(cut.count <= 62)
        #expect(MemoryStore.snippet("short text", around: "text") == "short text")
        #expect(MemoryStore.snippet("line one\nline two", around: "two") == "line one line two")
    }

    @Test("Conversations and their matching message are found by content")
    func search() throws {
        let store = MemoryStore.shared
        let id = store.insertConversation(title: "Search fixture Zyqxconv")
        defer { store.deleteConversation(id: id) }
        _ = store.insertMessage(conversationID: id, role: "user", kind: "message", content: "Remind me about the Zyqxplant watering")
        _ = store.insertMessage(conversationID: id, role: "assistant", kind: "message", content: "Sure, every Sunday.")

        let hits = ConversationStore.shared.conversations(matching: "zyqxplant")
        #expect(hits.contains { $0.id == id })
        let first = try #require(ConversationStore.shared.firstMessage(conversationID: id, matching: "zyqxplant"))
        #expect(first.isUser)
        #expect(ConversationStore.shared.firstMessage(conversationID: id, matching: "nothing-here-zz") == nil)
        #expect(ConversationStore.shared.conversations(matching: "no-such-term-zzq").allSatisfy { $0.id != id })
    }
}
