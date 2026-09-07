//
//  MemoryStore+Journal.swift
//  NeuraLink
//
//  CRUD for the Living Companion tables: `companion_journal` (per-session
//  reflection: diary + opener + notification line) and `persona_traits`
//  (distilled personality traits). Mirrors the prepared-statement + NSLock
//  style of MemoryStore+Conversations.swift.
//
//  `companion_journal.conversation_id` deliberately has NO foreign key —
//  deleting a conversation must not erase what the companion "remembers"
//  about it; the diary is the companion's memory, not the transcript's.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Journal writes

    /// Inserts one reflection row and returns its rowid (or -1 on failure).
    func insertJournalEntry(
        character: String,
        conversationID: Int64,
        diary: String,
        opener: String,
        notificationLine: String
    ) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        INSERT INTO companion_journal (character, conversation_id, diary, opener, notification_line)
        VALUES (?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        var newID: Int64 = -1
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, conversationID)
            sqlite3_bind_text(statement, 3, (diary as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (opener as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (notificationLine as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_DONE {
                newID = sqlite3_last_insert_rowid(db)
            } else {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                nlLog("[MemoryStore] Error inserting journal entry: \(errmsg)", level: .info)
            }
        }
        sqlite3_finalize(statement)
        return newID
    }

    /// Marks an entry's opener as consumed (greeting delivered once, ever).
    func markOpenerUsed(id: Int64) {
        setJournalFlag(id: id, column: "opener_used")
    }

    /// Marks an entry's notification as scheduled/delivered.
    func markJournalNotified(id: Int64) {
        setJournalFlag(id: id, column: "notified")
    }

    private func setJournalFlag(id: Int64, column: String) {
        lock.lock()
        defer { lock.unlock() }
        // `column` is an internal constant, never user input.
        let query = "UPDATE companion_journal SET \(column) = 1 WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func deleteJournalEntry(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM companion_journal WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Wipes a character's whole diary ("Reset personality" path).
    func deleteJournal(character: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM companion_journal WHERE character = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Journal reads

    /// Newest-first diary for one character.
    func journalEntries(character: String, limit: Int = 50) -> [JournalEntry] {
        fetchJournal(
            where: "character = ?", bindText: character,
            limit: limit)
    }

    /// The newest entry whose opener hasn't been spoken yet (absence greeting).
    func latestUnusedOpener(character: String) -> JournalEntry? {
        fetchJournal(
            where: "character = ? AND opener_used = 0 AND opener != ''", bindText: character,
            limit: 1
        ).first
    }

    /// The newest entry for a character regardless of flags (Phase 6 carry-over).
    func latestJournalEntry(character: String) -> JournalEntry? {
        fetchJournal(where: "character = ?", bindText: character, limit: 1).first
    }

    /// True when a conversation was already reflected on (dedupe guard).
    func hasJournalEntry(conversationID: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT COUNT(*) FROM companion_journal WHERE conversation_id = ?;"
        var statement: OpaquePointer?
        var count: Int32 = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, conversationID)
            if sqlite3_step(statement) == SQLITE_ROW {
                count = sqlite3_column_int(statement, 0)
            }
        }
        sqlite3_finalize(statement)
        return count > 0
    }

    private func fetchJournal(where clause: String, bindText: String, limit: Int) -> [JournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, character, conversation_id, diary, opener, notification_line,
               notified, opener_used, created_at
        FROM companion_journal WHERE \(clause) ORDER BY id DESC LIMIT ?;
        """
        var statement: OpaquePointer?
        var items: [JournalEntry] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (bindText as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(journalRow(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    private func journalRow(from statement: OpaquePointer?) -> JournalEntry {
        let createdRaw = sqlite3_column_text(statement, 8).map { String(cString: $0) } ?? ""
        return JournalEntry(
            id: sqlite3_column_int64(statement, 0),
            character: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
            conversationID: sqlite3_column_int64(statement, 2),
            diary: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
            opener: sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? "",
            notificationLine: sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "",
            notified: sqlite3_column_int(statement, 6) == 1,
            openerUsed: sqlite3_column_int(statement, 7) == 1,
            createdAt: Self.parseSQLiteTimestamp(createdRaw) ?? Date()
        )
    }

    // MARK: - Persona traits

    /// Inserts a trait, or bumps weight + updated_at when the same trait text
    /// (case-insensitive) already exists for the character.
    func upsertTrait(character: String, trait: String, weight: Double = 1.0) {
        lock.lock()
        defer { lock.unlock() }
        let update = """
        UPDATE persona_traits SET weight = ?, updated_at = CURRENT_TIMESTAMP
        WHERE character = ? AND trait = ? COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        var updatedRows: Int32 = 0
        if sqlite3_prepare_v2(db, update, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, weight)
            sqlite3_bind_text(statement, 2, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (trait as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_DONE {
                updatedRows = sqlite3_changes(db)
            }
        }
        sqlite3_finalize(statement)
        guard updatedRows == 0 else { return }

        let insert = "INSERT INTO persona_traits (character, trait, weight) VALUES (?, ?, ?);"
        statement = nil
        if sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (trait as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 3, weight)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Heaviest-first traits for one character.
    func traits(character: String, limit: Int = 10) -> [PersonaTrait] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, character, trait, weight, created_at, updated_at
        FROM persona_traits WHERE character = ?
        ORDER BY weight DESC, updated_at DESC LIMIT ?;
        """
        var statement: OpaquePointer?
        var items: [PersonaTrait] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                let created = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
                let updated = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
                items.append(
                    PersonaTrait(
                        id: sqlite3_column_int64(statement, 0),
                        character: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                        trait: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "",
                        weight: sqlite3_column_double(statement, 3),
                        createdAt: Self.parseSQLiteTimestamp(created) ?? Date(),
                        updatedAt: Self.parseSQLiteTimestamp(updated) ?? Date()
                    ))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    func deleteTrait(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM persona_traits WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Wipes a character's traits ("Reset personality" path).
    func deleteAllTraits(character: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM persona_traits WHERE character = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
}
