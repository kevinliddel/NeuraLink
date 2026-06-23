//
//  ConversationStore.swift
//  NeuraLink
//
//  Owns the "active conversation" (the current chat session) and brokers all
//  conversation/message persistence through MemoryStore. Thread-safe and
//  synchronous so it can be driven straight from the engine callbacks
//  (ChatTimelineStore), which run off the main thread — matching the old
//  flat-log write path it replaces.
//
//  Session model (per product decisions):
//    • New session = new chat. `activeConversationID` is nil ("pending") until
//      the first turn; the row is created lazily on the first appended message
//      so empty sessions never clutter the history list.
//    • Read-only history: the sidebar/transcript views read past conversations;
//      live talking always targets the active (current) conversation.
//    • Long-term memory (RAG facts) is separate and stays cross-session.
//

import Foundation

final class ConversationStore: @unchecked Sendable {
    static let shared = ConversationStore()

    private let lock = NSLock()
    private var _activeConversationID: Int64?

    private init() {}

    /// The current chat session's row id, or nil when a new chat is pending
    /// (no turn appended yet). Safe to read from any thread.
    var activeConversationID: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return _activeConversationID
    }

    // MARK: - Session lifecycle

    /// Begins a fresh chat. The next appended message creates the row, so
    /// repeated calls (e.g. on every launch) never leave empty conversations.
    func startNewChat() {
        lock.lock()
        _activeConversationID = nil
        lock.unlock()
    }

    /// Appends a turn to the active conversation, creating it lazily on the
    /// first call (title = the first message, truncated). Called by
    /// `ChatTimelineStore` for both the local LLM and OpenAI paths.
    func appendMessage(role: String, kind: String, content: String) {
        let convID: Int64
        lock.lock()
        if let active = _activeConversationID {
            convID = active
            lock.unlock()
        } else {
            let newID = MemoryStore.shared.insertConversation(
                title: Self.title(fromFirstMessage: content))
            guard newID > 0 else { lock.unlock(); return }
            _activeConversationID = newID
            convID = newID
            lock.unlock()
        }
        MemoryStore.shared.insertMessage(
            conversationID: convID, role: role, kind: kind, content: content)
        MemoryStore.shared.touchConversation(id: convID)
    }

    // MARK: - Reads (UI)

    func conversations(matching query: String = "") -> [Conversation] {
        MemoryStore.shared.fetchConversations(matching: query)
    }

    func messages(conversationID: Int64) -> [ConversationMessage] {
        MemoryStore.shared.fetchMessages(conversationID: conversationID)
    }

    func lastMessage(conversationID: Int64) -> ConversationMessage? {
        MemoryStore.shared.fetchLastMessage(conversationID: conversationID)
    }

    func deleteConversation(id: Int64) {
        MemoryStore.shared.deleteConversation(id: id)
        lock.lock()
        if _activeConversationID == id { _activeConversationID = nil }
        lock.unlock()
    }

    func renameConversation(id: Int64, title: String) {
        // A manual rename finalizes the title — mark it auto-titled so the
        // background titler won't overwrite the user's choice.
        MemoryStore.shared.renameConversation(id: id, title: title, autoTitled: true)
    }

    // MARK: - Title

    /// First line of the first message, trimmed to a short title. Falls back
    /// to "New Chat" for an empty/whitespace opener.
    private static func title(fromFirstMessage content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New Chat" }
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return String(firstLine.prefix(48))
    }
}
