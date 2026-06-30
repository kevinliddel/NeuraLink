//
//  MemoryStore.swift
//  NeuraLink
//
//  SQLite database setup, migration, and model structs for AI memory storage.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation
import SQLCipher

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

    /// Filename of the SQLite database; shared by the relocation migration
    /// and the live path resolution so the two stay in sync.
    private static let dbFileName = "neuralink_memory.sqlite"

    /// UserDefaults flag set once the legacy `Documents/` DB family has
    /// been moved into the protected directory. See `relocateLegacyDBIfNeeded`.
    private static let dbRelocationMigrationFlag = "com.neuralink.migration.dbRelocate.v1"

    private init() {
        let path = Self.resolveDBPath()
        self.dbPath = path

        // Opt-in: if the user has flipped on SQLCipher and we
        // haven't converted the on-disk DB yet, perform the one-shot
        // plaintext-to-encrypted conversion now. See
        // `MemoryStore+SQLCipher.swift` for the conversion logic and the
        // two-flag (intent vs realised) state machine.
        if Self.isSQLCipherEnabled && !Self.isSQLCipherActive {
            Self.convertPlaintextToSQLCipher(at: path)
        }

        setupDatabase()
        migrateIfNeeded()
        Self.protectDBFamily(at: path)
    }

    /// Resolves the SQLite path, running the one-shot relocation from
    /// `Documents/` to `Application Support/private/` if it hasn't fired
    /// yet. Falls back to the legacy `Documents/` path if `ProtectedStorage`
    /// is unavailable — the DB stays unencrypted-at-rest in that case but
    /// the app remains functional and the failure is logged.
    private static func resolveDBPath() -> String {
        do {
            try relocateLegacyDBIfNeeded()
            let dir = try ProtectedStorage.privateApplicationSupportURL()
            return dir.appendingPathComponent(dbFileName).path
        } catch {
            nlLog(
                "[MemoryStore] Protected location unavailable, falling back to Documents (unencrypted at rest): \(error)",
                level: .error)
            let docs = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first!
            return docs.appendingPathComponent(dbFileName).path
        }
    }

    /// Atomically moves the legacy `Documents/<dbFileName>` family (the
    /// main `.sqlite` plus any transient `-journal`/`-wal`/`-shm` siblings)
    /// into `Application Support/private/`. Idempotent — guarded by the
    /// `dbRelocationMigrationFlag` so it runs at most once.
    ///
    /// On any move failure, rolls back the moves performed so far. SQLite
    /// refuses to open a `.sqlite` whose sibling journal has gone missing,
    /// so a half-migrated state would corrupt the user's chat history.
    private static func relocateLegacyDBIfNeeded() throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: dbRelocationMigrationFlag) else { return }

        let fileManager = FileManager.default
        let documents = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask).first!
        let legacyMain = documents.appendingPathComponent(dbFileName)

        // Fresh install — nothing to move. Mark the flag so we don't
        // re-stat `Documents/` on every launch forever.
        guard fileManager.fileExists(atPath: legacyMain.path) else {
            defaults.set(true, forKey: dbRelocationMigrationFlag)
            return
        }

        let targetDir = try ProtectedStorage.privateApplicationSupportURL()
        let siblingSuffixes = ["", "-journal", "-wal", "-shm"]

        var moved: [(URL, URL)] = []
        do {
            for suffix in siblingSuffixes {
                let src = documents.appendingPathComponent("\(dbFileName)\(suffix)")
                guard fileManager.fileExists(atPath: src.path) else { continue }

                let dst = targetDir.appendingPathComponent("\(dbFileName)\(suffix)")
                // A prior interrupted migration could leave a stale
                // destination; overwriting it preserves the legacy state
                // as the source of truth.
                if fileManager.fileExists(atPath: dst.path) {
                    try fileManager.removeItem(at: dst)
                }
                try fileManager.moveItem(at: src, to: dst)
                moved.append((src, dst))
            }
        } catch {
            for (src, dst) in moved.reversed() {
                try? fileManager.moveItem(at: dst, to: src)
            }
            throw error
        }

        nlLog(
            "[MemoryStore] Relocated DB family (\(moved.count) file(s)) from Documents/ to protected directory",
            level: .info)
        defaults.set(true, forKey: dbRelocationMigrationFlag)
    }

    /// Belt-and-suspenders: applies the Data Protection class to each
    /// member of the DB file family. Files created inside the protected
    /// directory inherit the class on creation, but this catches files
    /// that may have been created before the directory attribute applied
    /// — e.g. a `-journal` that SQLite produces between calls or a file
    /// left over from the relocation move.
    private static func protectDBFamily(at path: String) {
        let baseURL = URL(fileURLWithPath: path)
        let parent = baseURL.deletingLastPathComponent()
        let stem = baseURL.lastPathComponent

        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = parent.appendingPathComponent("\(stem)\(suffix)")
            do {
                try ProtectedStorage.protect(file)
            } catch {
                nlLog(
                    "[MemoryStore] Failed to set protection class on \(file.lastPathComponent): \(error)",
                    level: .warning)
            }
        }
    }

    // MARK: - Schema

    private func setupDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            nlLog("[MemoryStore] Error: Could not open database.", level: .error)
            return
        }

        // SQLCipher keying MUST happen before any other DB operation —
        // the library refuses to key a connection that has already
        // touched the file. When `isSQLCipherActive` is false (default),
        // this branch is skipped and the DB is plaintext-on-disk (still
        // protected at the filesystem layer by iOS Data Protection).
        if Self.isSQLCipherActive {
            guard Self.keyDatabase(db) else {
                sqlite3_close(db)
                db = nil
                return
            }
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
        CREATE TABLE IF NOT EXISTS conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            auto_titled INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            kind TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, id);
        CREATE TABLE IF NOT EXISTS character_ai (
            character TEXT NOT NULL,
            engine    TEXT NOT NULL,
            prompt    TEXT,
            voice     TEXT,
            name      TEXT,
            PRIMARY KEY (character, engine)
        );
        """

        // Enforce ON DELETE CASCADE for messages when a conversation is
        // deleted. Off by default per-connection in SQLite; deleteConversation
        // also deletes explicitly, so this is belt-and-suspenders.
        _ = sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)

        if sqlite3_exec(db, createTableQuery, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            nlLog("[MemoryStore] Error creating tables: \(errmsg)", level: .info)
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
        // One-shot: fold the legacy flat `chat_events` log into a single
        // conversation so upgrading users keep their history under the new
        // session model. Idempotent (UserDefaults-guarded). See
        // MemoryStore+Conversations.swift.
        migrateLegacyChatEventsIfNeeded()

        // One-shot: import per-character prompts/voices from the legacy
        // PersonaStore / LocalLLMPromptStore / PersonaVoiceStore (JSON +
        // UserDefaults) into the `character_ai` table. See MemoryStore+Personas.swift.
        migratePersonaStoresIfNeeded()
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
