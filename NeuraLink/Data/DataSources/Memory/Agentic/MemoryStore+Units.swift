//
//  MemoryStore+Units.swift
//  NeuraLink
//
//  Schema migration + CRUD for agentic memory units (docs/AGENTIC_MEMORY.md).
//  Extends the legacy `memories` table in place so existing rows keep
//  working: they are back-filled as `fact_type = 'raw'` (dialogue) or
//  `'world'` (legacy `source = 'fact'` rows) with tokens for the BM25 arm.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Migration

    /// Adds the agentic-memory columns/tables. Idempotent; each step is
    /// guarded by a column/table existence check so it is safe on every
    /// launch and on both plaintext and SQLCipher databases.
    func migrateAgenticMemoryIfNeeded() {
        let columns: [(String, String)] = [
            ("fact_type", "TEXT NOT NULL DEFAULT 'raw'"),
            ("context", "TEXT NOT NULL DEFAULT ''"),
            ("tokens", "TEXT NOT NULL DEFAULT ''"),
            ("mentioned_at", "DATETIME"),
            ("occurred_start", "DATETIME"),
            ("occurred_end", "DATETIME"),
            ("proof_count", "INTEGER NOT NULL DEFAULT 1"),
            ("source_ids", "TEXT NOT NULL DEFAULT ''"),
            ("consolidated_at", "DATETIME")
        ]
        var addedAny = false
        for (name, decl) in columns where !columnExists(table: "memories", column: name) {
            _ = sqlite3_exec(db, "ALTER TABLE memories ADD COLUMN \(name) \(decl);", nil, nil, nil)
            addedAny = true
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS memory_entities (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            canonical_name TEXT NOT NULL COLLATE NOCASE UNIQUE,
            kind TEXT NOT NULL DEFAULT '',
            first_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            mention_count INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS memory_unit_entities (
            unit_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            entity_id INTEGER NOT NULL REFERENCES memory_entities(id) ON DELETE CASCADE,
            PRIMARY KEY (unit_id, entity_id)
        );
        CREATE INDEX IF NOT EXISTS idx_unit_entities_entity ON memory_unit_entities(entity_id);
        CREATE TABLE IF NOT EXISTS memory_links (
            from_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            to_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            link_type TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1.0,
            PRIMARY KEY (from_id, to_id, link_type)
        );
        CREATE INDEX IF NOT EXISTS idx_links_to ON memory_links(to_id);
        CREATE TABLE IF NOT EXISTS mental_models (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            character TEXT NOT NULL DEFAULT '',
            slug TEXT NOT NULL,
            question TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            is_stale INTEGER NOT NULL DEFAULT 1,
            last_refreshed DATETIME,
            last_memory_id INTEGER NOT NULL DEFAULT 0,
            UNIQUE (character, slug)
        );
        CREATE INDEX IF NOT EXISTS idx_memories_fact_type ON memories(fact_type);
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            nlLog("[MemoryStore] Error creating agentic memory tables: \(errmsg)", level: .error)
        }

        if addedAny { backfillLegacyUnits() }
    }

    /// One-shot back-fill after the columns were added: legacy `source =
    /// 'fact'` rows become world facts, everything else stays raw dialogue;
    /// `mentioned_at` mirrors the ingestion timestamp and `tokens` is
    /// computed so the BM25 arm can see old rows immediately.
    private func backfillLegacyUnits() {
        _ = sqlite3_exec(
            db,
            """
            UPDATE memories SET fact_type = 'world' WHERE source = 'fact' AND fact_type = 'raw';
            UPDATE memories SET mentioned_at = timestamp WHERE mentioned_at IS NULL;
            """,
            nil, nil, nil)

        var rows: [(Int64, String)] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, text FROM memories WHERE tokens = '';", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1))))
            }
        }
        sqlite3_finalize(statement)

        for (id, text) in rows {
            let tokens = MemoryTextIndex.tokenString(for: text)
            var update: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE memories SET tokens = ? WHERE id = ?;", -1, &update, nil) == SQLITE_OK {
                sqlite3_bind_text(update, 1, (tokens as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(update, 2, id)
                _ = sqlite3_step(update)
            }
            sqlite3_finalize(update)
        }
        nlLog("[MemoryStore] Back-filled \(rows.count) legacy memory rows for agentic memory", level: .info)
    }

    // MARK: - Insert

    /// Inserts one memory unit and returns its rowid (or -1 on failure).
    /// Entity links are written separately via `linkEntities(unitID:names:)`.
    func insertUnit(
        text: String,
        context: String = "",
        vector: [Double],
        factType: MemoryFactType,
        source: String,
        pinned: Bool = false,
        mentionedAt: Date = Date(),
        occurredStart: Date? = nil,
        occurredEnd: Date? = nil,
        proofCount: Int = 1,
        sourceIDs: [Int64] = []
    ) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        INSERT INTO memories
            (text, vector, source, pinned, fact_type, context, tokens, mentioned_at,
             occurred_start, occurred_end, proof_count, source_ids, consolidated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        var newID: Int64 = -1
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return -1 }
        let tokens = MemoryTextIndex.tokenString(for: text)
        let data = Data(bytes: vector, count: vector.count * MemoryLayout<Double>.size)
        sqlite3_bind_text(statement, 1, (text as NSString).utf8String, -1, nil)
        data.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(statement, 2, ptr.baseAddress, Int32(data.count), nil)
        }
        sqlite3_bind_text(statement, 3, (source as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, pinned ? 1 : 0)
        sqlite3_bind_text(statement, 5, (factType.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (context as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (tokens as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, (Self.sqliteFormatter.string(from: mentionedAt) as NSString).utf8String, -1, nil)
        Self.bindOptionalDate(statement, 9, occurredStart)
        Self.bindOptionalDate(statement, 10, occurredEnd)
        sqlite3_bind_int(statement, 11, Int32(proofCount))
        sqlite3_bind_text(statement, 12, (Self.joinIDs(sourceIDs) as NSString).utf8String, -1, nil)
        // Observations are born consolidated; raw dialogue never consolidates.
        if factType == .observation || factType == .raw {
            sqlite3_bind_text(statement, 13, (Self.sqliteFormatter.string(from: Date()) as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 13)
        }
        if sqlite3_step(statement) == SQLITE_DONE {
            newID = sqlite3_last_insert_rowid(db)
        } else {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            nlLog("[MemoryStore] Error inserting memory unit: \(errmsg)", level: .error)
        }
        sqlite3_finalize(statement)
        return newID
    }

    // MARK: - Read

    /// Every unit of the given fact types (all types when nil), newest first.
    /// Entities are attached in a second query keyed by unit id.
    func fetchUnits(factTypes: Set<MemoryFactType>? = nil) -> [MemoryUnit] {
        lock.lock()
        defer { lock.unlock() }
        var query = "SELECT \(Self.unitColumns) FROM memories"
        if let types = factTypes, !types.isEmpty {
            let list = types.map { "'\($0.rawValue)'" }.joined(separator: ",")
            query += " WHERE fact_type IN (\(list))"
        }
        query += " ORDER BY id DESC;"
        return runUnitQuery(query) { _ in }
    }

    func fetchUnit(id: Int64) -> MemoryUnit? {
        lock.lock()
        defer { lock.unlock() }
        return runUnitQuery("SELECT \(Self.unitColumns) FROM memories WHERE id = ?;") { statement in
            sqlite3_bind_int64(statement, 1, id)
        }.first
    }

    func fetchUnits(ids: [Int64]) -> [MemoryUnit] {
        guard !ids.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let list = ids.map(String.init).joined(separator: ",")
        return runUnitQuery("SELECT \(Self.unitColumns) FROM memories WHERE id IN (\(list));") { _ in }
    }

    /// World/experience facts not yet folded into an observation.
    func fetchUnconsolidatedUnits(limit: Int) -> [MemoryUnit] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT \(Self.unitColumns) FROM memories
        WHERE consolidated_at IS NULL AND fact_type IN ('world', 'experience')
        ORDER BY id ASC LIMIT ?;
        """
        return runUnitQuery(query) { statement in sqlite3_bind_int(statement, 1, Int32(limit)) }
    }

    func countUnits(factType: MemoryFactType) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM memories WHERE fact_type = ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (factType.rawValue as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW { count = Int(sqlite3_column_int(statement, 0)) }
        }
        sqlite3_finalize(statement)
        return count
    }

    /// Highest memory id — the "has anything changed" watermark for
    /// mental-model delta refresh.
    func latestUnitID() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var maxID: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM memories;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            maxID = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(statement)
        return maxID
    }

    // MARK: - Update / delete

    func markConsolidated(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let list = ids.map(String.init).joined(separator: ",")
        _ = sqlite3_exec(
            db, "UPDATE memories SET consolidated_at = CURRENT_TIMESTAMP WHERE id IN (\(list));",
            nil, nil, nil)
    }

    /// Rewrites an observation's text/vector and evidence. `proofCount` and
    /// `sourceIDs` replace the stored values (callers pass the union).
    func updateObservation(id: Int64, text: String, vector: [Double], proofCount: Int, sourceIDs: [Int64]) {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        UPDATE memories SET text = ?, vector = ?, tokens = ?, proof_count = ?, source_ids = ?,
            mentioned_at = CURRENT_TIMESTAMP
        WHERE id = ? AND fact_type = 'observation';
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return }
        let data = Data(bytes: vector, count: vector.count * MemoryLayout<Double>.size)
        sqlite3_bind_text(statement, 1, (text as NSString).utf8String, -1, nil)
        data.withUnsafeBytes { ptr in
            _ = sqlite3_bind_blob(statement, 2, ptr.baseAddress, Int32(data.count), nil)
        }
        sqlite3_bind_text(statement, 3, (MemoryTextIndex.tokenString(for: text) as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(proofCount))
        sqlite3_bind_text(statement, 5, (Self.joinIDs(sourceIDs) as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 6, id)
        _ = sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func deleteUnit(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM memories WHERE id = ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Row mapping

    static let unitColumns = """
    id, text, vector, timestamp, source, pinned, fact_type, context, tokens, mentioned_at,
    occurred_start, occurred_end, proof_count, source_ids, consolidated_at
    """

    /// Caller must hold `lock`.
    private func runUnitQuery(_ query: String, bind: (OpaquePointer?) -> Void) -> [MemoryUnit] {
        var statement: OpaquePointer?
        var rows: [MemoryUnit] = []
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(unitRow(from: statement, entities: []))
        }
        sqlite3_finalize(statement)
        guard !rows.isEmpty else { return [] }
        let names = entityNamesByUnit(ids: rows.map(\.id))
        return rows.map { row in
            guard let list = names[row.id], !list.isEmpty else { return row }
            return row.withEntities(list)
        }
    }

    private func unitRow(from statement: OpaquePointer?, entities: [String]) -> MemoryUnit {
        let blobPtr = sqlite3_column_blob(statement, 2)
        let blobSize = Int(sqlite3_column_bytes(statement, 2))
        let vector = Array(UnsafeBufferPointer(
            start: blobPtr?.assumingMemoryBound(to: Double.self),
            count: blobSize / MemoryLayout<Double>.size))
        let created = Self.columnDate(statement, 3) ?? Date()
        let sourceIDs = Self.text(statement, 13).split(separator: ",").compactMap { Int64($0) }
        return MemoryUnit(
            id: sqlite3_column_int64(statement, 0),
            text: Self.text(statement, 1),
            context: Self.text(statement, 7),
            vector: vector,
            factType: MemoryFactType(rawValue: Self.text(statement, 6)) ?? .raw,
            source: Self.text(statement, 4),
            pinned: sqlite3_column_int(statement, 5) != 0,
            createdAt: created,
            mentionedAt: Self.columnDate(statement, 9) ?? created,
            occurredStart: Self.columnDate(statement, 10),
            occurredEnd: Self.columnDate(statement, 11),
            proofCount: Int(sqlite3_column_int(statement, 12)),
            sourceIDs: sourceIDs,
            consolidatedAt: Self.columnDate(statement, 14),
            tokens: Self.text(statement, 8),
            entities: entities
        )
    }

    static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    static func columnDate(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return parseSQLiteTimestamp(text(statement, index))
    }

    static func bindOptionalDate(_ statement: OpaquePointer?, _ index: Int32, _ date: Date?) {
        if let date {
            sqlite3_bind_text(statement, index, (sqliteFormatter.string(from: date) as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func joinIDs(_ ids: [Int64]) -> String {
        ids.map(String.init).joined(separator: ",")
    }
}

extension MemoryUnit {
    func withEntities(_ names: [String]) -> MemoryUnit {
        MemoryUnit(
            id: id, text: text, context: context, vector: vector, factType: factType,
            source: source, pinned: pinned, createdAt: createdAt, mentionedAt: mentionedAt,
            occurredStart: occurredStart, occurredEnd: occurredEnd, proofCount: proofCount,
            sourceIDs: sourceIDs, consolidatedAt: consolidatedAt, tokens: tokens, entities: names)
    }
}
