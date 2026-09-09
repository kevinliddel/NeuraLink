//
//  MemoryStore+Affinity.swift
//  NeuraLink
//
//  Aggregate queries feeding the relationship model (CompanionAffinity):
//  a real connection grows over shared DAYS and depth, not message volume,
//  so the curve needs more than a row count. Prepared-statement + NSLock
//  style, matching the other MemoryStore extensions.
//
//  Created by Dedicatus on 09/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// Number of distinct calendar days (UTC) on which the user actually
    /// spoke — the backbone of the affinity curve: it can't be ground up in
    /// one long night of chatting.
    func distinctUserMessageDays() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT COUNT(DISTINCT DATE(timestamp)) FROM messages
        WHERE role = 'user' AND kind = 'message';
        """
        var statement: OpaquePointer?
        var count: Int32 = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW {
            count = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return Int(count)
    }

    /// When the user last spoke, across all conversations (UTC-parsed).
    /// Nil before the first ever turn.
    func lastUserMessageAt() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT timestamp FROM messages
        WHERE role = 'user' AND kind = 'message'
        ORDER BY id DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        var date: Date?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW,
            let raw = sqlite3_column_text(statement, 0) {
            date = Self.parseSQLiteTimestamp(String(cString: raw))
        }
        sqlite3_finalize(statement)
        return date
    }

    /// Total reflections across all characters — a proxy for "sessions that
    /// actually meant something" (short chats never reflect).
    func journalEntryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT COUNT(*) FROM companion_journal;"
        var statement: OpaquePointer?
        var count: Int32 = 0
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW {
            count = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        return Int(count)
    }
}
