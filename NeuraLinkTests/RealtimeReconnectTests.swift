//
//  RealtimeReconnectTests.swift
//  NeuraLinkTests
//
//  Pure-logic tests for the Realtime auto-reconnect
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B1): backoff schedule and the
//  context replay events sent after a reconnect.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Realtime reconnect")
struct RealtimeReconnectTests {

    @Test("Backoff doubles and stops after the last attempt")
    func backoff() {
        #expect(ReconnectPolicy.delay(forAttempt: 1) == 1)
        #expect(ReconnectPolicy.delay(forAttempt: 2) == 2)
        #expect(ReconnectPolicy.delay(forAttempt: 5) == 16)
        #expect(ReconnectPolicy.delay(forAttempt: 6) == nil)
        #expect(ReconnectPolicy.delay(forAttempt: 0) == nil)
    }

    @Test("Context replay keeps the last spoken turns in order with the right roles")
    func replayItems() throws {
        let now = Date()
        var messages: [ConversationMessage] = []
        for index in 0..<10 {
            let isUser = index.isMultiple(of: 2)
            messages.append(ConversationMessage(
                id: Int64(index), conversationID: 1, role: isUser ? "user" : "assistant",
                kind: "message", content: "turn \(index)", timestamp: now))
        }
        messages.append(ConversationMessage(
            id: 99, conversationID: 1, role: "tool", kind: "tool_call", content: "weather", timestamp: now))

        let items = OpenAIRealtimeManager.contextReplayItems(from: messages)
        #expect(items.count == ReconnectPolicy.replayTurns)
        let first = try #require(items.first?["item"] as? [String: Any])
        let last = try #require(items.last?["item"] as? [String: Any])
        #expect(first["role"] as? String == "user")
        #expect(last["role"] as? String == "assistant")
        let content = try #require((last["content"] as? [[String: Any]])?.first)
        #expect(content["type"] as? String == "text")
        #expect(content["text"] as? String == "turn 9")
        #expect(items.allSatisfy { $0["type"] as? String == "conversation.item.create" })
    }
}
