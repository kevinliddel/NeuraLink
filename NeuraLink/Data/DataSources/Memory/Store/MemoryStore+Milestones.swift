//
//  MemoryStore+Milestones.swift
//  NeuraLink
//
//  CRUD for `companion_milestones` — keepsake milestones (Living Companion,
//  docs/LIVING_COMPANION.md). One row per (character, kind); `INSERT OR
//  IGNORE` makes "record" idempotent so every call site can fire freely.
//  Prepared-statement + NSLock style, like the other MemoryStore extensions.
//
//  Created by Dedicatus on 12/10/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// Records a milestone for a character. Returns true only the first time.
    @discardableResult
    func recordMilestone(character: String, kind: MilestoneKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let query = "INSERT OR IGNORE INTO companion_milestones (character, kind) VALUES (?, ?);"
        var statement: OpaquePointer?
        var inserted = false
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (kind.rawValue as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_DONE {
                inserted = sqlite3_changes(db) > 0
            } else {
                let errmsg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
                nlLog("[MemoryStore] Error recording milestone: \(errmsg)", level: .info)
            }
        }
        sqlite3_finalize(statement)
        return inserted
    }

    /// Oldest-first keepsakes for one character. Rows written by a newer
    /// build with kinds this one doesn't know are skipped, never deleted.
    func milestones(character: String) -> [CompanionMilestone] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT kind, achieved_at, celebrated_at FROM companion_milestones
        WHERE character = ? ORDER BY achieved_at ASC, kind ASC;
        """
        var statement: OpaquePointer?
        var items: [CompanionMilestone] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW {
                let rawKind = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                guard let kind = MilestoneKind(rawValue: rawKind) else { continue }
                let achievedRaw = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                let celebratedRaw = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                items.append(
                    CompanionMilestone(
                        kind: kind,
                        character: character,
                        achievedAt: Self.parseSQLiteTimestamp(achievedRaw) ?? Date(),
                        celebratedAt: celebratedRaw.flatMap(Self.parseSQLiteTimestamp)
                    ))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    /// Stamps when the persona first brought a milestone up; later calls
    /// leave the original time alone so the celebration hold is measured
    /// from the first mention.
    func markMilestoneCelebrated(character: String, kind: MilestoneKind) {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        UPDATE companion_milestones SET celebrated_at = CURRENT_TIMESTAMP
        WHERE character = ? AND kind = ? AND celebrated_at IS NULL;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (kind.rawValue as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Wipes a character's keepsakes (tests and character removal).
    func deleteMilestones(character: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM companion_milestones WHERE character = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
}
