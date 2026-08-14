//
//  MemoryStore+ImportedCharacters.swift
//  NeuraLink
//
//  SQL persistence for user-imported VRM characters: the `imported_characters`
//  table. Each row pins one imported `.vrm` — file path (relative to the
//  protected directory), byte size + SHA-256 integrity pin, VRM license
//  metadata, and the canonical display name. Prompt/voice/per-engine name stay
//  in `character_ai` (MemoryStore+Personas.swift), keyed by the same slug.
//
//  Methods are NSLock-guarded (mirrors MemoryStore+Personas.swift) and callable
//  off the main thread — the registry refreshes during scene loads.
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Insert

    /// Inserts a new imported character. Returns the full row on success, nil
    /// on failure — including UNIQUE violations on `slug` (caller must unique
    /// slugs first) or `sha256` (same file already imported).
    func insertImportedCharacter(_ draft: ImportedCharacterDraft) -> ImportedCharacter? {
        lock.lock()
        let sql = """
        INSERT INTO imported_characters
            (slug, display_name, file_path, file_size, sha256,
             thumbnail_path, source_filename, vrm_spec, meta_name, meta_authors,
             meta_license_url, meta_avatar_permission, meta_commercial_usage)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        var rowID: Int64?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindText(statement, 1, draft.slug.lowercased())
            bindText(statement, 2, draft.displayName)
            bindText(statement, 3, draft.filePath)
            sqlite3_bind_int64(statement, 4, draft.fileSize)
            bindText(statement, 5, draft.sha256.lowercased())
            bindText(statement, 6, draft.thumbnailPath)
            bindText(statement, 7, draft.sourceFilename)
            bindText(statement, 8, draft.vrmSpec)
            bindText(statement, 9, draft.metaName)
            bindText(statement, 10, draft.metaAuthors)
            bindText(statement, 11, draft.metaLicenseURL)
            bindText(statement, 12, draft.metaAvatarPermission)
            bindText(statement, 13, draft.metaCommercialUsage)
            if sqlite3_step(statement) == SQLITE_DONE {
                rowID = sqlite3_last_insert_rowid(db)
            } else {
                nlLog("[MemoryStore] imported_characters INSERT step failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
            }
        } else {
            nlLog("[MemoryStore] imported_characters INSERT prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
        lock.unlock()

        guard let rowID else { return nil }
        return importedCharacter(id: rowID)
    }

    // MARK: - Fetch

    /// All imported characters, newest first. Quarantined rows (failed
    /// integrity re-check) are excluded unless explicitly requested.
    func fetchImportedCharacters(includeQuarantined: Bool = false) -> [ImportedCharacter] {
        lock.lock()
        defer { lock.unlock() }
        var sql = "SELECT \(Self.importedColumns) FROM imported_characters"
        if !includeQuarantined { sql += " WHERE quarantined = 0" }
        sql += " ORDER BY id DESC;"

        var statement: OpaquePointer?
        var rows: [ImportedCharacter] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(importedCharacterRow(from: statement))
            }
        } else {
            nlLog("[MemoryStore] imported_characters SELECT prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
        return rows
    }

    func importedCharacter(slug: String) -> ImportedCharacter? {
        firstImportedCharacter(where: "slug = ?", bind: slug.lowercased())
    }

    /// Duplicate detection: the same bytes already imported under another slug.
    func importedCharacter(sha256: String) -> ImportedCharacter? {
        firstImportedCharacter(where: "sha256 = ?", bind: sha256.lowercased())
    }

    private func importedCharacter(id: Int64) -> ImportedCharacter? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT \(Self.importedColumns) FROM imported_characters WHERE id = ?;"
        var statement: OpaquePointer?
        var row: ImportedCharacter?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            if sqlite3_step(statement) == SQLITE_ROW {
                row = importedCharacterRow(from: statement)
            }
        }
        sqlite3_finalize(statement)
        return row
    }

    private func firstImportedCharacter(where clause: String, bind value: String) -> ImportedCharacter? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT \(Self.importedColumns) FROM imported_characters WHERE \(clause) LIMIT 1;"
        var statement: OpaquePointer?
        var row: ImportedCharacter?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindText(statement, 1, value)
            if sqlite3_step(statement) == SQLITE_ROW {
                row = importedCharacterRow(from: statement)
            }
        } else {
            nlLog("[MemoryStore] imported_characters lookup prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
        return row
    }

    // MARK: - Update

    func updateImportedCharacterDisplayName(slug: String, displayName: String) {
        execImportedUpdate(
            "UPDATE imported_characters SET display_name = ?, updated_at = CURRENT_TIMESTAMP WHERE slug = ?;",
            texts: [displayName, slug.lowercased()], label: "display_name")
    }

    func setImportedCharacterQuarantined(slug: String, _ quarantined: Bool) {
        execImportedUpdate(
            "UPDATE imported_characters SET quarantined = \(quarantined ? 1 : 0), updated_at = CURRENT_TIMESTAMP WHERE slug = ?;",
            texts: [slug.lowercased()], label: "quarantined")
    }

    /// nil clears the path (the card falls back to the letter placeholder).
    func updateImportedCharacterThumbnailPath(slug: String, path: String?) {
        execImportedUpdate(
            "UPDATE imported_characters SET thumbnail_path = ?, updated_at = CURRENT_TIMESTAMP WHERE slug = ?;",
            texts: [path, slug.lowercased()], label: "thumbnail_path")
    }

    // MARK: - Delete

    /// Removes the SQL row only. File cleanup and `character_ai` row cleanup
    /// are the delete flow's job (ImportedCharacterStore.delete).
    func deleteImportedCharacter(slug: String) {
        execImportedUpdate(
            "DELETE FROM imported_characters WHERE slug = ?;",
            texts: [slug.lowercased()], label: "delete")
    }

    /// Removes every `character_ai` row (all engines) for a character key.
    /// Used when an imported character is deleted so its prompts/voices don't
    /// orphan — and silently resurrect if the slug is ever reused.
    func deletePersonaRows(character: String) {
        execImportedUpdate(
            "DELETE FROM character_ai WHERE character = ?;",
            texts: [character.lowercased()], label: "character_ai delete")
    }

    // MARK: - Helpers

    private static let importedColumns = """
    id, slug, display_name, file_path, file_size, sha256, \
    thumbnail_path, source_filename, vrm_spec, meta_name, meta_authors, \
    meta_license_url, meta_avatar_permission, meta_commercial_usage, \
    quarantined, created_at, updated_at
    """

    private func importedCharacterRow(from statement: OpaquePointer?) -> ImportedCharacter {
        ImportedCharacter(
            id: sqlite3_column_int64(statement, 0),
            slug: String(cString: sqlite3_column_text(statement, 1)),
            displayName: String(cString: sqlite3_column_text(statement, 2)),
            filePath: String(cString: sqlite3_column_text(statement, 3)),
            fileSize: sqlite3_column_int64(statement, 4),
            sha256: String(cString: sqlite3_column_text(statement, 5)),
            thumbnailPath: columnText(statement, 6),
            sourceFilename: columnText(statement, 7),
            vrmSpec: columnText(statement, 8),
            metaName: columnText(statement, 9),
            metaAuthors: columnText(statement, 10),
            metaLicenseURL: columnText(statement, 11),
            metaAvatarPermission: columnText(statement, 12),
            metaCommercialUsage: columnText(statement, 13),
            quarantined: sqlite3_column_int(statement, 14) != 0,
            // Nil-safe despite NOT NULL: pre-fix rows created without the
            // constraint could carry NULL, which must not crash the mapper.
            createdAt: columnText(statement, 15).flatMap(Self.parseSQLiteTimestamp) ?? Date(),
            updatedAt: columnText(statement, 16).flatMap(Self.parseSQLiteTimestamp) ?? Date()
        )
    }

    /// Runs a single UPDATE/DELETE whose placeholders are all text (nil
    /// binds SQL NULL). SQL strings are compile-time constants; only values
    /// are bound.
    private func execImportedUpdate(_ sql: String, texts: [String?], label: String) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (offset, text) in texts.enumerated() {
                bindText(statement, Int32(offset + 1), text)
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                nlLog("[MemoryStore] imported_characters \(label) step failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
            }
        } else {
            nlLog("[MemoryStore] imported_characters \(label) prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
    }

    /// Binds text (TRANSIENT — SQLite copies the bridged bytes immediately),
    /// or NULL when nil. Same rationale as bindPersonaText.
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transientDestructor)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static let transientDestructor = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    /// Nullable text column read: nil for SQL NULL.
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
}
