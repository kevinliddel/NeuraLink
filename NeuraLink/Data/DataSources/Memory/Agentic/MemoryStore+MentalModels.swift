//
//  MemoryStore+MentalModels.swift
//  NeuraLink
//
//  CRUD for `mental_models` — standing answers to fixed questions that the
//  prompt builders read without any retrieval or LLM call
//  (docs/AGENTIC_MEMORY.md §Mental models).
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// Ensures a (character, slug) row exists with `question`; never
    /// overwrites existing content.
    func ensureMentalModel(character: String, slug: String, question: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        INSERT OR IGNORE INTO mental_models (character, slug, question) VALUES (?, ?, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (slug as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (question as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func fetchMentalModel(character: String, slug: String) -> MentalModel? {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT \(Self.mentalModelColumns) FROM mental_models WHERE character = ? AND slug = ?;"
        var statement: OpaquePointer?
        var model: MentalModel?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (slug as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW { model = mentalModelRow(statement) }
        }
        sqlite3_finalize(statement)
        return model
    }

    func fetchMentalModels(character: String) -> [MentalModel] {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT \(Self.mentalModelColumns) FROM mental_models WHERE character = ? OR character = '' ORDER BY id;"
        var statement: OpaquePointer?
        var rows: [MentalModel] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW { rows.append(mentalModelRow(statement)) }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func updateMentalModel(id: Int64, content: String, lastMemoryID: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        UPDATE mental_models SET content = ?, is_stale = 0, last_refreshed = CURRENT_TIMESTAMP,
            last_memory_id = ? WHERE id = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (content as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, lastMemoryID)
            sqlite3_bind_int64(statement, 3, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Flags every mental model as needing a refresh (called after
    /// consolidation or a manual memory edit).
    func markMentalModelsStale() {
        lock.lock()
        defer { lock.unlock() }
        _ = sqlite3_exec(db, "UPDATE mental_models SET is_stale = 1;", nil, nil, nil)
    }

    private static let mentalModelColumns =
        "id, character, slug, question, content, is_stale, last_refreshed, last_memory_id"

    private func mentalModelRow(_ statement: OpaquePointer?) -> MentalModel {
        MentalModel(
            id: sqlite3_column_int64(statement, 0),
            character: Self.text(statement, 1),
            slug: Self.text(statement, 2),
            question: Self.text(statement, 3),
            content: Self.text(statement, 4),
            isStale: sqlite3_column_int(statement, 5) != 0,
            lastRefreshed: Self.columnDate(statement, 6),
            lastMemoryID: sqlite3_column_int64(statement, 7))
    }
}
