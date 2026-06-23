//
//  Conversation.swift
//  NeuraLink
//
//  Domain types for the chat-history session model: a `Conversation` is one
//  chat thread (a "session"), and `ConversationMessage` is a single persisted
//  turn within it. Persisted in the encrypted MemoryStore DB
//  (`conversations` + `messages` tables); see MemoryStore+Conversations.swift.
//
//  Distinct from `LLMChatMessage` (LLMEngineProtocol.swift), which is the
//  transient role/content pair fed to the LLM prompt template.
//

import Foundation

/// A chat session shown as a row in the history sidebar.
struct Conversation: Identifiable, Hashable {
    let id: Int64
    var title: String
    let createdAt: Date
    var updatedAt: Date
}

/// A single persisted turn within a conversation.
/// - `role`: "user" | "assistant" | "tool"
/// - `kind`: "message" | "tool_call"
struct ConversationMessage: Identifiable, Hashable {
    let id: Int64
    let conversationID: Int64
    let role: String
    let kind: String
    let content: String
    let timestamp: Date

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
    var isTool: Bool { role == "tool" }
}
