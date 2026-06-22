//
//  MemoryStore+Conversations.swift
//  NeuraLink
//
//  Read/write query methods for the session-based chat model: the
//  `conversations` and `messages` tables. Mirrors the prepared-statement +
//  NSLock style of MemoryStore+Queries.swift. Replaces the flat `chat_events`
//  log as the source of truth for chat history (chat_events is migrated once
//  and then dormant — see `migrateLegacyChatEventsIfNeeded`).
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Conversations

    /// Inserts a new conversation and returns its rowid (or -1 on failure).
    func insertConversation(title: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let query = "INSERT INTO conversations (title) VALUES (?);"
        var statement: OpaquePointer?
        var newID: Int64 = -1
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_DONE {
                newID = sqlite3_last_insert_rowid(db)
            } else {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                nlLog("[MemoryStore] Error inserting conversation: \(errmsg)", level: .info)
            }
        }
        sqlite3_finalize(statement)
        return newID
    }

    /// Bumps `updated_at` so the conversation sorts to the top of the list.
    func touchConversation(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let query = "UPDATE conversations SET updated_at = CURRENT_TIMESTAMP WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func renameConversation(id: Int64, title: String, autoTitled: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let query = "UPDATE conversations SET title = ?, auto_titled = ? WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, autoTitled ? 1 : 0)
            sqlite3_bind_int64(statement, 3, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Deletes a conversation and all its messages. Explicit cascade so it
    /// works regardless of the `foreign_keys` pragma state.
    func deleteConversation(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        for sql in [
            "DELETE FROM messages WHERE conversation_id = ?;",
            "DELETE FROM conversations WHERE id = ?;"
        ] {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int64(statement, 1, id)
                _ = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    /// All conversations, newest-activity first. When `query` is non-empty,
    /// matches the title OR any message content (case-insensitive substring).
    func fetchConversations(matching query: String = "") -> [Conversation] {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        if trimmed.isEmpty {
            sql = "SELECT id, title, created_at, updated_at FROM conversations ORDER BY updated_at DESC;"
        } else {
            sql = """
            SELECT id, title, created_at, updated_at FROM conversations
            WHERE title LIKE ?1
               OR id IN (SELECT conversation_id FROM messages WHERE content LIKE ?1)
            ORDER BY updated_at DESC;
            """
        }
        var statement: OpaquePointer?
        var items: [Conversation] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if !trimmed.isEmpty {
                let like = "%\(trimmed)%"
                sqlite3_bind_text(statement, 1, (like as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(conversationRow(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    /// Drops conversations (and their messages) untouched since `cutoff`.
    func pruneConversations(olderThan cutoff: Date) {
        lock.lock()
        defer { lock.unlock() }
        let ts = Self.sqliteFormatter.string(from: cutoff)
        for sql in [
            "DELETE FROM messages WHERE conversation_id IN (SELECT id FROM conversations WHERE updated_at < ?);",
            "DELETE FROM conversations WHERE updated_at < ?;"
        ] {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (ts as NSString).utf8String, -1, nil)
                _ = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Messages

    func insertMessage(conversationID: Int64, role: String, kind: String, content: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = "INSERT INTO messages (conversation_id, role, kind, content) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, conversationID)
            sqlite3_bind_text(statement, 2, (role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (kind as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (content as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// All messages in a conversation, chronological (oldest first).
    func fetchMessages(conversationID: Int64) -> [ConversationMessage] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, conversation_id, role, kind, content, timestamp
        FROM messages WHERE conversation_id = ? ORDER BY id ASC;
        """
        var statement: OpaquePointer?
        var items: [ConversationMessage] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, conversationID)
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(conversationMessageRow(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    /// The most recent `limit` messages, returned chronological — for the
    /// LLM verbatim window (current chat only).
    func fetchRecentMessages(conversationID: Int64, limit: Int) -> [ConversationMessage] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, conversation_id, role, kind, content, timestamp FROM (
            SELECT id, conversation_id, role, kind, content, timestamp
            FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT ?
        ) ORDER BY id ASC;
        """
        var statement: OpaquePointer?
        var items: [ConversationMessage] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, conversationID)
            sqlite3_bind_int(statement, 2, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(conversationMessageRow(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    /// Most recent `limit` messages across ALL conversations, newest first.
    /// Used by compaction (fact extraction) and the relationship meter, which
    /// are cross-session concerns.
    func fetchRecentMessagesAcrossAll(limit: Int) -> [ConversationMessage] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, conversation_id, role, kind, content, timestamp
        FROM messages ORDER BY id DESC LIMIT ?;
        """
        var statement: OpaquePointer?
        var items: [ConversationMessage] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(conversationMessageRow(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    func fetchLastMessage(conversationID: Int64) -> ConversationMessage? {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, conversation_id, role, kind, content, timestamp
        FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        var item: ConversationMessage?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, conversationID)
            if sqlite3_step(statement) == SQLITE_ROW {
                item = conversationMessageRow(from: statement)
            }
        }
        sqlite3_finalize(statement)
        return item
    }

    /// Count of messages matching a role+kind across all conversations — used
    /// by the relationship meter for "user turns".
    func countMessages(role: String, kind: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT COUNT(*) FROM messages WHERE role = ? AND kind = ?;"
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (kind as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }
        sqlite3_finalize(statement)
        return count
    }

    // MARK: - Legacy migration

    /// Folds the flat `chat_events` log into a single "Earlier messages"
    /// conversation, once, so upgrading users don't lose history. Maps the
    /// legacy role "ai" → "assistant". Guarded by a UserDefaults flag.
    func migrateLegacyChatEventsIfNeeded() {
        let flag = "com.neuralink.migration.chatEventsToConversation.v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }

        lock.lock()

        var count = 0
        var countStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chat_events;", -1, &countStmt, nil) == SQLITE_OK,
           sqlite3_step(countStmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int(countStmt, 0))
        }
        sqlite3_finalize(countStmt)

        guard count > 0 else {
            lock.unlock()
            defaults.set(true, forKey: flag)  // fresh install — nothing to migrate
            return
        }

        var convID: Int64 = -1
        var insStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO conversations (title) VALUES ('Earlier messages');", -1, &insStmt, nil) == SQLITE_OK,
           sqlite3_step(insStmt) == SQLITE_DONE {
            convID = sqlite3_last_insert_rowid(db)
        }
        sqlite3_finalize(insStmt)

        guard convID > 0 else {
            lock.unlock()
            return  // leave the flag unset so we retry next launch
        }

        // convID is a trusted Int64 from last_insert_rowid (not user input).
        let copy = """
        INSERT INTO messages (conversation_id, role, kind, content, timestamp)
        SELECT \(convID),
               CASE role WHEN 'ai' THEN 'assistant' ELSE role END,
               kind, detail, timestamp
        FROM chat_events ORDER BY id ASC;
        """
        _ = sqlite3_exec(db, copy, nil, nil, nil)
        _ = sqlite3_exec(db, """
            UPDATE conversations SET
                created_at = (SELECT MIN(timestamp) FROM messages WHERE conversation_id = \(convID)),
                updated_at = (SELECT MAX(timestamp) FROM messages WHERE conversation_id = \(convID))
            WHERE id = \(convID);
            """, nil, nil, nil)

        lock.unlock()
        defaults.set(true, forKey: flag)
        nlLog("[MemoryStore] Migrated \(count) legacy chat_events into conversation \(convID).", level: .info)
    }

    // MARK: - Row helpers

    private func conversationRow(from statement: OpaquePointer?) -> Conversation {
        let id = sqlite3_column_int64(statement, 0)
        let title = String(cString: sqlite3_column_text(statement, 1))
        let created = Self.parseSQLiteTimestamp(String(cString: sqlite3_column_text(statement, 2))) ?? Date()
        let updated = Self.parseSQLiteTimestamp(String(cString: sqlite3_column_text(statement, 3))) ?? Date()
        return Conversation(id: id, title: title, createdAt: created, updatedAt: updated)
    }

    private func conversationMessageRow(from statement: OpaquePointer?) -> ConversationMessage {
        let id = sqlite3_column_int64(statement, 0)
        let convID = sqlite3_column_int64(statement, 1)
        let role = String(cString: sqlite3_column_text(statement, 2))
        let kind = String(cString: sqlite3_column_text(statement, 3))
        let content = String(cString: sqlite3_column_text(statement, 4))
        let ts = Self.parseSQLiteTimestamp(String(cString: sqlite3_column_text(statement, 5))) ?? Date()
        return ConversationMessage(
            id: id, conversationID: convID, role: role, kind: kind, content: content, timestamp: ts)
    }
}
