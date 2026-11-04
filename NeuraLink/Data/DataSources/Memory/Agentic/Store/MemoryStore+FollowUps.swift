//
//  MemoryStore+FollowUps.swift
//  NeuraLink
//
//  Bookkeeping for character-initiated follow-ups: 
//  which (unit, kind) pairs already fired and which units the user muted with "Not this".
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    func migrateFollowUpsIfNeeded() {
        let schema = """
        CREATE TABLE IF NOT EXISTS follow_ups (
            unit_id INTEGER NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            fired_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (unit_id, kind)
        );
        CREATE TABLE IF NOT EXISTS follow_up_mutes (
            unit_id INTEGER PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
            muted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            nlLog("[MemoryStore] Error creating follow-up tables: \(errmsg)", level: .error)
        }
    }

    /// "unitID:kind" keys of follow-ups that already fired.
    func firedFollowUps() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var keys = Set<String>()
        if sqlite3_prepare_v2(db, "SELECT unit_id, kind FROM follow_ups;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                keys.insert("\(sqlite3_column_int64(statement, 0)):\(Self.text(statement, 1))")
            }
        }
        sqlite3_finalize(statement)
        return keys
    }

    func recordFollowUp(unitID: Int64, kind: String) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO follow_ups (unit_id, kind) VALUES (?, ?);", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, unitID)
            sqlite3_bind_text(statement, 2, (kind as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func muteFollowUps(unitID: Int64) {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO follow_up_mutes (unit_id) VALUES (?);", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, unitID)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func mutedFollowUpUnits() -> Set<Int64> {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var ids = Set<Int64>()
        if sqlite3_prepare_v2(db, "SELECT unit_id FROM follow_up_mutes;", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW { ids.insert(sqlite3_column_int64(statement, 0)) }
        }
        sqlite3_finalize(statement)
        return ids
    }
}
