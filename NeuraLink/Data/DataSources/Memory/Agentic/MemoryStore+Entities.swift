//
//  MemoryStore+Entities.swift
//  NeuraLink
//
//  Entity table, unit↔entity links and unit↔unit links for the graph arm
//  of recall (docs/AGENTIC_MEMORY.md §Recall). Mirrors the prepared-
//  statement + NSLock style of the other MemoryStore extensions.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Entities

    /// Upserts `names` and links each to `unitID`. Names are canonicalised
    /// case-insensitively by the UNIQUE COLLATE NOCASE constraint.
    func linkEntities(unitID: Int64, names: [String], kind: String = "") {
        let cleaned = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard unitID > 0, !cleaned.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for name in cleaned {
            let upsert = """
            INSERT INTO memory_entities (canonical_name, kind) VALUES (?, ?)
            ON CONFLICT(canonical_name) DO UPDATE SET
                mention_count = mention_count + 1, last_seen = CURRENT_TIMESTAMP;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, upsert, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (kind as NSString).utf8String, -1, nil)
                _ = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)

            guard let entityID = entityID(named: name) else { continue }
            var link: OpaquePointer?
            if sqlite3_prepare_v2(
                db, "INSERT OR IGNORE INTO memory_unit_entities (unit_id, entity_id) VALUES (?, ?);",
                -1, &link, nil) == SQLITE_OK {
                sqlite3_bind_int64(link, 1, unitID)
                sqlite3_bind_int64(link, 2, entityID)
                _ = sqlite3_step(link)
            }
            sqlite3_finalize(link)
        }
    }

    /// Caller must hold `lock`.
    private func entityID(named name: String) -> Int64? {
        var statement: OpaquePointer?
        var id: Int64?
        if sqlite3_prepare_v2(db, "SELECT id FROM memory_entities WHERE canonical_name = ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW { id = sqlite3_column_int64(statement, 0) }
        }
        sqlite3_finalize(statement)
        return id
    }

    /// Entity names for each unit id. Caller must hold `lock`.
    func entityNamesByUnit(ids: [Int64]) -> [Int64: [String]] {
        guard !ids.isEmpty else { return [:] }
        let list = ids.map(String.init).joined(separator: ",")
        let query = """
        SELECT ue.unit_id, e.canonical_name FROM memory_unit_entities ue
        JOIN memory_entities e ON e.id = ue.entity_id
        WHERE ue.unit_id IN (\(list));
        """
        var statement: OpaquePointer?
        var result: [Int64: [String]] = [:]
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let unitID = sqlite3_column_int64(statement, 0)
                result[unitID, default: []].append(Self.text(statement, 1))
            }
        }
        sqlite3_finalize(statement)
        return result
    }

    /// Unit ids that share at least one entity with any of `names`, with
    /// the number of shared entities per unit. Excludes `excluding`.
    func unitsSharingEntities(names: [String], excluding: Set<Int64>) -> [Int64: Int] {
        guard !names.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        let query = """
        SELECT ue.unit_id, COUNT(*) FROM memory_unit_entities ue
        JOIN memory_entities e ON e.id = ue.entity_id
        WHERE e.canonical_name IN (\(placeholders))
        GROUP BY ue.unit_id;
        """
        var statement: OpaquePointer?
        var result: [Int64: Int] = [:]
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            for (i, name) in names.enumerated() {
                sqlite3_bind_text(statement, Int32(i + 1), (name as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let unitID = sqlite3_column_int64(statement, 0)
                guard !excluding.contains(unitID) else { continue }
                result[unitID] = Int(sqlite3_column_int(statement, 1))
            }
        }
        sqlite3_finalize(statement)
        return result
    }

    func fetchEntities(limit: Int = 50) -> [MemoryEntity] {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT id, canonical_name, kind, mention_count FROM memory_entities ORDER BY mention_count DESC LIMIT ?;"
        var statement: OpaquePointer?
        var rows: [MemoryEntity] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(MemoryEntity(
                    id: sqlite3_column_int64(statement, 0),
                    canonicalName: Self.text(statement, 1),
                    kind: Self.text(statement, 2),
                    mentionCount: Int(sqlite3_column_int(statement, 3))))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    // MARK: - Links

    func insertLinks(_ links: [MemoryLink]) {
        guard !links.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let query = "INSERT OR REPLACE INTO memory_links (from_id, to_id, link_type, weight) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return }
        for link in links where link.fromID != link.toID {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, link.fromID)
            sqlite3_bind_int64(statement, 2, link.toID)
            sqlite3_bind_text(statement, 3, (link.kind.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 4, link.weight)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// All links touching any of `ids`, in either direction.
    func fetchLinks(touching ids: [Int64]) -> [MemoryLink] {
        guard !ids.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let list = ids.map(String.init).joined(separator: ",")
        let query = """
        SELECT from_id, to_id, link_type, weight FROM memory_links
        WHERE from_id IN (\(list)) OR to_id IN (\(list));
        """
        var statement: OpaquePointer?
        var rows: [MemoryLink] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = MemoryLink.Kind(rawValue: Self.text(statement, 2)) else { continue }
                rows.append(MemoryLink(
                    fromID: sqlite3_column_int64(statement, 0),
                    toID: sqlite3_column_int64(statement, 1),
                    kind: kind,
                    weight: sqlite3_column_double(statement, 3)))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    /// Clears every agentic-memory side table (units cascade from
    /// `DELETE FROM memories`; entities and mental models do not).
    /// Caller must hold `lock`.
    func clearAgenticMemoryTables() {
        _ = sqlite3_exec(
            db,
            """
            DELETE FROM memory_links;
            DELETE FROM memory_unit_entities;
            DELETE FROM memory_entities;
            DELETE FROM mental_models;
            """,
            nil, nil, nil)
    }
}
