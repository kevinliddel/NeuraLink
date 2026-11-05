//
//  MemoryStore+Lore.swift
//  NeuraLink
//
//  `companion_lore_reveals`: which authored lore fragments have been offered
//  to a character's persona, and when — Inner life
//  (docs/Companion/LIVING_COMPANION.md). Keyed by (character, fragment);
//  offering a fragment again refreshes its timestamp. Mirrors the
//  prepared-statement + NSLock style of MemoryStore+Journal.swift.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// Notes that `fragmentID` was offered to the persona now.
    func recordLoreReveal(character: String, fragmentID: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        INSERT INTO companion_lore_reveals (character, fragment, revealed_at)
        VALUES (?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(character, fragment) DO UPDATE SET revealed_at = CURRENT_TIMESTAMP;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (fragmentID as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) != SQLITE_DONE {
                nlLog("[MemoryStore] Error recording lore reveal: \(String(cString: sqlite3_errmsg(db)!))", level: .info)
            }
        }
        sqlite3_finalize(statement)
    }

    /// Everything offered to one character's persona, newest first.
    func loreReveals(character: String) -> [LoreReveal] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT fragment, revealed_at FROM companion_lore_reveals
        WHERE character = ? ORDER BY revealed_at DESC, fragment;
        """
        var statement: OpaquePointer?
        var items: [LoreReveal] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW {
                let raw = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                items.append(LoreReveal(
                    fragmentID: sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "",
                    revealedAt: Self.parseSQLiteTimestamp(raw) ?? Date()))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    /// Forgets what was shared, so the stories can be told again ("Reset
    /// personality" path).
    func deleteLoreReveals(character: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM companion_lore_reveals WHERE character = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
}
