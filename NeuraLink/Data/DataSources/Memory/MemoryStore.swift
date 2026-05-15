//
//  MemoryStore.swift
//  NeuraLink
//
//  SQLite database setup, migration, and model structs for AI memory storage.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation
import SQLite3

struct MemoryItem {
    let id: Int64
    let text: String
    let vector: [Double]
    let timestamp: Date
    let source: String
    let pinned: Bool
}

struct ChatEventItem: Identifiable {
    let id: Int64
    let role: String
    let kind: String
    let title: String
    let detail: String
    let pinned: Bool
    let timestamp: Date
}

struct FactItem: Identifiable {
    let id: Int64
    let subject: String
    let predicate: String
    let object: String
    let timestamp: Date
}

final class MemoryStore {
    static let shared = MemoryStore()

    var db: OpaquePointer?
    let lock = NSLock()
    private let dbPath: String

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.dbPath = docs.appendingPathComponent("neuralink_memory.sqlite").path
        setupDatabase()
        migrateIfNeeded()
    }

    // MARK: - Schema

    private func setupDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[MemoryStore] Error: Could not open database.")
            return
        }

        let createTableQuery = """
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            text TEXT NOT NULL,
            vector BLOB NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS knowledge_graph (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            subject TEXT NOT NULL,
            predicate TEXT NOT NULL,
            object TEXT NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS chat_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            detail TEXT NOT NULL,
            pinned INTEGER DEFAULT 0,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """

        if sqlite3_exec(db, createTableQuery, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("[MemoryStore] Error creating tables: \(errmsg)")
        }
    }

    private func migrateIfNeeded() {
        if !columnExists(table: "memories", column: "source") {
            _ = sqlite3_exec(
                db,
                "ALTER TABLE memories ADD COLUMN source TEXT DEFAULT 'unknown';",
                nil, nil, nil
            )
        }
        if !columnExists(table: "memories", column: "pinned") {
            _ = sqlite3_exec(
                db,
                "ALTER TABLE memories ADD COLUMN pinned INTEGER DEFAULT 0;",
                nil, nil, nil
            )
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        let query = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let cName = sqlite3_column_text(statement, 1) else { continue }
                if String(cString: cName).caseInsensitiveCompare(column) == .orderedSame {
                    found = true
                    break
                }
            }
        }
        sqlite3_finalize(statement)
        return found
    }

    // MARK: - Timestamp parsing

    static let sqliteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parseSQLiteTimestamp(_ raw: String) -> Date? {
        if let date = sqliteFormatter.date(from: raw) { return date }
        if let dot = raw.firstIndex(of: ".") {
            return sqliteFormatter.date(from: String(raw[..<dot]))
        }
        return nil
    }

    deinit {
        sqlite3_close(db)
    }
}
