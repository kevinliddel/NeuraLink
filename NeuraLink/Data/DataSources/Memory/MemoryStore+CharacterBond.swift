//
//  MemoryStore+CharacterBond.swift
//  NeuraLink
//
//  One bond per character (docs/LIVING_COMPANION.md). The relationship
//  meter, the count-based keepsakes, "time apart" and the carry-over line
//  describe the user and ONE character, so every message and every
//  remembered fact records the character it was shared with. What a
//  character KNOWS is a separate question, answered by the memory banks
//  (MemoryBanks and the "Characters share memories" setting): a new
//  character can know the user's sister's name and still be at "New".
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Schema

    /// Adds the `character` columns and, the first time, attributes the rows
    /// written before them. Called from `migrateIfNeeded` at open.
    func migrateCharacterAttribution(fallback: () -> String) {
        let addMessages = !columnExists(table: "messages", column: "character")
        let addFacts = !columnExists(table: "knowledge_graph", column: "character")
        if addMessages {
            _ = sqlite3_exec(db, "ALTER TABLE messages ADD COLUMN character TEXT NOT NULL DEFAULT '';", nil, nil, nil)
        }
        if addFacts {
            _ = sqlite3_exec(
                db, "ALTER TABLE knowledge_graph ADD COLUMN character TEXT NOT NULL DEFAULT '';", nil, nil, nil)
        }
        _ = sqlite3_exec(
            db, "CREATE INDEX IF NOT EXISTS idx_messages_character ON messages(character COLLATE NOCASE, role, kind);",
            nil, nil, nil)
        guard addMessages || addFacts else { return }
        let attributed = attributeLegacyRows(fallback: fallback())
        nlLog(
            "[MemoryStore] Per-character bond: attributed \(attributed.messages) messages and \(attributed.facts) facts",
            level: .info)
    }

    /// Gives every unattributed message and fact a character. A message a
    /// diary entry covered goes to that entry's character; the rest of a
    /// reflected conversation to its latest diary character; anything else
    /// to the character with the most diary entries, else `fallback`. A fact
    /// goes to the character of the last message before it.
    @discardableResult
    func attributeLegacyRows(fallback: String) -> (messages: Int, facts: Int) {
        lock.lock()
        defer { lock.unlock() }
        let owner = mostJournaledCharacterLocked() ?? fallback
        var messages = 0
        // 1. The diary entry whose watermark first covers the message.
        messages += execLocked("""
            UPDATE messages SET character = (
                SELECT j.character FROM companion_journal j
                WHERE j.conversation_id = messages.conversation_id AND j.last_message_id >= messages.id
                ORDER BY j.last_message_id ASC, j.id ASC LIMIT 1)
            WHERE character = '' AND EXISTS (
                SELECT 1 FROM companion_journal j
                WHERE j.conversation_id = messages.conversation_id AND j.last_message_id >= messages.id);
            """)
        // 2. The rest of a reflected conversation: its latest diary character.
        messages += execLocked("""
            UPDATE messages SET character = (
                SELECT j.character FROM companion_journal j
                WHERE j.conversation_id = messages.conversation_id ORDER BY j.id DESC LIMIT 1)
            WHERE character = '' AND conversation_id IN (SELECT conversation_id FROM companion_journal);
            """)
        // 3. Everything else.
        messages += execLocked("UPDATE messages SET character = ? WHERE character = '';", owner)
        let facts = execLocked("""
            UPDATE knowledge_graph SET character = COALESCE((
                SELECT m.character FROM messages m
                WHERE m.character != '' AND m.timestamp <= knowledge_graph.timestamp
                ORDER BY m.timestamp DESC, m.id DESC LIMIT 1), ?)
            WHERE character = '';
            """, owner)
        return (messages, facts)
    }

    // MARK: - Carry-over

    /// The last spoken line between the user and `character` outside the
    /// active conversation — what the carry-over line quotes, so a character
    /// never "remembers" another character's words as its own.
    func lastExchange(character: String, excludingConversation active: Int64?) -> ConversationMessage? {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, conversation_id, role, kind, content, timestamp FROM messages
        WHERE character = ? COLLATE NOCASE AND kind = 'message' AND content != '' AND conversation_id != ?
        ORDER BY id DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        var message: ConversationMessage?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, active ?? -1)
            if sqlite3_step(statement) == SQLITE_ROW { message = conversationMessageRow(from: statement) }
        }
        sqlite3_finalize(statement)
        return message
    }

    // MARK: - Helpers (caller holds `lock`)

    private func mostJournaledCharacterLocked() -> String? {
        let query = """
        SELECT character FROM companion_journal WHERE character != ''
        GROUP BY character COLLATE NOCASE ORDER BY COUNT(*) DESC, MAX(id) DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        var name: String?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
            name = String(cString: raw)
        }
        sqlite3_finalize(statement)
        return name
    }

    /// Runs one statement, binding `argument` to its `?` when given; returns
    /// the rows it changed.
    private func execLocked(_ query: String, _ argument: String? = nil) -> Int {
        var statement: OpaquePointer?
        var changed = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            if let argument { sqlite3_bind_text(statement, 1, (argument as NSString).utf8String, -1, nil) }
            if sqlite3_step(statement) == SQLITE_DONE { changed = Int(sqlite3_changes(db)) }
        } else {
            nlLog("[MemoryStore] Attribution step failed: \(String(cString: sqlite3_errmsg(db)))", level: .error)
        }
        sqlite3_finalize(statement)
        return changed
    }
}
