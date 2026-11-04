//
//  MemoryStore+Affinity.swift
//  NeuraLink
//
//  Aggregate queries feeding the relationship model (CompanionAffinity):
//  a real connection grows over shared DAYS and depth, not message volume,
//  so the curve needs more than a row count. Every input is counted for ONE
//  character — the bond is between the user and that character
//  (MemoryStore+CharacterBond). Prepared-statement + NSLock style, matching
//  the other MemoryStore extensions.
//
//  Created by Dedicatus on 09/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// User turns spoken to `character`.
    func userTurnCount(character: String) -> Int {
        scalarInt("""
            SELECT COUNT(*) FROM messages
            WHERE role = 'user' AND kind = 'message' AND character = ? COLLATE NOCASE;
            """, character)
    }

    /// Number of distinct calendar days (UTC) on which the user actually
    /// spoke to `character` — the backbone of the affinity curve: it can't
    /// be ground up in one long night of chatting.
    func distinctUserMessageDays(character: String) -> Int {
        scalarInt("""
            SELECT COUNT(DISTINCT DATE(timestamp)) FROM messages
            WHERE role = 'user' AND kind = 'message' AND character = ? COLLATE NOCASE;
            """, character)
    }

    /// When the user last spoke to `character` (UTC-parsed). Nil before
    /// their first turn together.
    func lastUserMessageAt(character: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT timestamp FROM messages
        WHERE role = 'user' AND kind = 'message' AND character = ? COLLATE NOCASE
        ORDER BY id DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        var date: Date?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
                date = Self.parseSQLiteTimestamp(String(cString: raw))
            }
        }
        sqlite3_finalize(statement)
        return date
    }

    /// `character`'s reflections — a proxy for "sessions that actually meant
    /// something" (short chats never reflect).
    func journalEntryCount(character: String) -> Int {
        scalarInt("SELECT COUNT(*) FROM companion_journal WHERE character = ? COLLATE NOCASE;", character)
    }

    /// Facts the user told `character` (remember_fact). What the character
    /// can RECALL is wider when characters share memories; what it LEARNED
    /// with the user is only these.
    func factCount(character: String) -> Int {
        scalarInt("SELECT COUNT(*) FROM knowledge_graph WHERE character = ? COLLATE NOCASE;", character)
    }

    /// One integer from `query`, with `argument` bound to its single `?`.
    func scalarInt(_ query: String, _ argument: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var count: Int32 = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (argument as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW { count = sqlite3_column_int(statement, 0) }
        }
        sqlite3_finalize(statement)
        return Int(count)
    }
}
