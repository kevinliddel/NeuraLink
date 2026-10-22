//
//  MemoryStore+JournalCalendar.swift
//  NeuraLink
//
//  Message-table reads behind the journal calendar and the "time apart"
//  prompt line — Living Companion (docs/LIVING_COMPANION.md). Timestamps
//  are the UTC strings SQLite wrote; callers group them into local days.
//  Both are per character: the calendar shows the days you spent with the
//  character whose journal it is, and "time apart" is time apart from them.
//  Prepared-statement + NSLock style, like the other extensions.
//
//  Created by Dedicatus on 13/10/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// User turns to `character` in `[start, end)`, oldest first, with their
    /// conversation.
    func userTurnStamps(between start: Date, and end: Date, character: String) -> [UserTurnStamp] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT conversation_id, timestamp FROM messages
        WHERE role = 'user' AND kind = 'message' AND timestamp >= ? AND timestamp < ?
          AND character = ? COLLATE NOCASE
        ORDER BY id ASC;
        """
        var statement: OpaquePointer?
        var stamps: [UserTurnStamp] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (Self.sqliteFormatter.string(from: start) as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (Self.sqliteFormatter.string(from: end) as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (character as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW {
                let raw = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                guard let at = Self.parseSQLiteTimestamp(raw) else { continue }
                stamps.append(UserTurnStamp(conversationID: sqlite3_column_int64(statement, 0), at: at))
            }
        }
        sqlite3_finalize(statement)
        return stamps
    }

    /// The last user turn to `character` strictly before `cutoff` — "when
    /// did we last talk before this visit began". Nil when the user never
    /// spoke to them before it.
    func lastUserMessageAt(before cutoff: Date, character: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT timestamp FROM messages
        WHERE role = 'user' AND kind = 'message' AND timestamp < ? AND character = ? COLLATE NOCASE
        ORDER BY id DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        var date: Date?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (Self.sqliteFormatter.string(from: cutoff) as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (character as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
                date = Self.parseSQLiteTimestamp(String(cString: raw))
            }
        }
        sqlite3_finalize(statement)
        return date
    }
}
