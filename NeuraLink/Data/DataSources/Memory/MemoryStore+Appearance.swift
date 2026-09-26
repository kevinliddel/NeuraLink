//
//  MemoryStore+Appearance.swift
//  NeuraLink
//
//  SQL persistence for per-character appearance customization: the
//  `character_appearance` table, one JSON `AppearanceSpec` per character
//  key (lowercased slug == persona identifier). Backs AppearanceStore.
//
//  NSLock-guarded like the other MemoryStore extensions; callable off the
//  main thread (the scene view applies a stored look right after a load).
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Reads

    func appearanceSpecJSON(character: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT spec FROM character_appearance WHERE character = ?;"
        var statement: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindAppearanceText(statement, 1, character.lowercased())
            if sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
                result = String(cString: text)
            }
        } else {
            nlLog("[MemoryStore] appearance SELECT prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
        return result
    }

    // MARK: - Writes

    /// Inserts or replaces the character's spec. `INSERT OR REPLACE` is safe
    /// here because `character` is the table's PRIMARY KEY from creation
    /// (no legacy schema variant exists for this table).
    func setAppearanceSpecJSON(_ json: String, character: String) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
            INSERT OR REPLACE INTO character_appearance (character, spec, updated_at)
            VALUES (?, ?, CURRENT_TIMESTAMP);
            """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindAppearanceText(statement, 1, character.lowercased())
            bindAppearanceText(statement, 2, json)
            if sqlite3_step(statement) != SQLITE_DONE {
                nlLog("[MemoryStore] appearance upsert step failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
            }
        } else {
            nlLog("[MemoryStore] appearance upsert prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
    }

    func deleteAppearanceSpec(character: String) {
        lock.lock()
        defer { lock.unlock() }
        let sql = "DELETE FROM character_appearance WHERE character = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindAppearanceText(statement, 1, character.lowercased())
            if sqlite3_step(statement) != SQLITE_DONE {
                nlLog("[MemoryStore] appearance delete step failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
            }
        } else {
            nlLog("[MemoryStore] appearance delete prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Helpers

    /// TRANSIENT bind — SQLite copies the bridged bytes immediately (same
    /// rationale as bindPersonaText).
    private func bindAppearanceText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
}
