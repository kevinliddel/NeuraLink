//
//  MemoryStore+Queries.swift
//  NeuraLink
//
//  Read/write query methods for memories, chat events, and facts.
//

import Foundation
import SQLCipher

extension MemoryStore {

    // MARK: - Memories

    func insert(text: String, vector: [Double], source: String, pinned: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let query = "INSERT INTO memories (text, vector, source, pinned) VALUES (?, ?, ?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (text as NSString).utf8String, -1, nil)
            // Store vector as BLOB
            let data = Data(bytes: vector, count: vector.count * MemoryLayout<Double>.size)
            data.withUnsafeBytes { ptr in
                sqlite3_bind_blob(statement, 2, ptr.baseAddress, Int32(data.count), nil)
            }
            sqlite3_bind_text(statement, 3, (source as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 4, pinned ? 1 : 0)
            if sqlite3_step(statement) != SQLITE_DONE {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                nlLog("[MemoryStore] Error inserting memory: \(errmsg)", level: .info)
            }
        }
        sqlite3_finalize(statement)
    }

    func fetchAll() -> [MemoryItem] {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT id, text, vector, timestamp, source, pinned FROM memories ORDER BY timestamp DESC;"
        var statement: OpaquePointer?
        var items = [MemoryItem]()
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let text = String(cString: sqlite3_column_text(statement, 1))
                let blobPtr = sqlite3_column_blob(statement, 2)
                let blobSize = Int(sqlite3_column_bytes(statement, 2))
                let vectorCount = blobSize / MemoryLayout<Double>.size
                let vector = Array(UnsafeBufferPointer(
                    start: blobPtr?.assumingMemoryBound(to: Double.self),
                    count: vectorCount
                ))
                let timestampString = String(cString: sqlite3_column_text(statement, 3))
                let timestamp = Self.parseSQLiteTimestamp(timestampString) ?? Date()
                let source = String(cString: sqlite3_column_text(statement, 4))
                let pinned = sqlite3_column_int(statement, 5) != 0
                items.append(MemoryItem(
                    id: id, text: text, vector: vector,
                    timestamp: timestamp, source: source, pinned: pinned
                ))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    func deleteMemories(since: Date, includePinned: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let ts = Self.sqliteFormatter.string(from: since)
        let query = includePinned
            ? "DELETE FROM memories WHERE timestamp >= ?;"
            : "DELETE FROM memories WHERE timestamp >= ? AND pinned = 0;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (ts as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func pruneMemories(olderThan cutoff: Date) {
        lock.lock()
        defer { lock.unlock() }
        let ts = Self.sqliteFormatter.string(from: cutoff)
        let query = "DELETE FROM memories WHERE timestamp < ? AND pinned = 0;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (ts as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Chat timeline

    func insertChatEvent(role: String, kind: String, title: String, detail: String, pinned: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let query = "INSERT INTO chat_events (role, kind, title, detail, pinned) VALUES (?, ?, ?, ?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (role as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (kind as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (detail as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 5, pinned ? 1 : 0)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func fetchChatEvents(limit: Int = 300) -> [ChatEventItem] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, role, kind, title, detail, pinned, timestamp
        FROM chat_events ORDER BY timestamp DESC LIMIT ?;
        """
        var statement: OpaquePointer?
        var items: [ChatEventItem] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(chatEventItem(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    func fetchChatEvents(limit: Int, offset: Int) -> [ChatEventItem] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, role, kind, title, detail, pinned, timestamp
        FROM chat_events ORDER BY timestamp DESC LIMIT ? OFFSET ?;
        """
        var statement: OpaquePointer?
        var items: [ChatEventItem] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            sqlite3_bind_int(statement, 2, Int32(offset))
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(chatEventItem(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    func countChatEvents() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM chat_events;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return count
    }

    func setChatEventPinned(id: Int64, pinned: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let query = "UPDATE chat_events SET pinned = ? WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
            sqlite3_bind_int64(statement, 2, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func deleteChatEvent(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM chat_events WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func deleteChatEvents(since: Date, includePinned: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let ts = Self.sqliteFormatter.string(from: since)
        let query = includePinned
            ? "DELETE FROM chat_events WHERE timestamp >= ?;"
            : "DELETE FROM chat_events WHERE timestamp >= ? AND pinned = 0;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (ts as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func pruneChatEvents(olderThan cutoff: Date) {
        lock.lock()
        defer { lock.unlock() }
        let ts = Self.sqliteFormatter.string(from: cutoff)
        let query = "DELETE FROM chat_events WHERE timestamp < ? AND pinned = 0;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (ts as NSString).utf8String, -1, nil)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM memories;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM knowledge_graph;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM chat_events;", nil, nil, nil)
    }

    // MARK: - Knowledge Graph

    func insertFact(subject: String, predicate: String, object: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = "INSERT INTO knowledge_graph (subject, predicate, object) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (subject as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (predicate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (object as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) != SQLITE_DONE {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                nlLog("[MemoryStore] Error inserting fact: \(errmsg)", level: .info)
            }
        }
        sqlite3_finalize(statement)
    }

    func fetchAllFacts() -> [FactItem] {
        lock.lock()
        defer { lock.unlock() }
        let query = "SELECT id, subject, predicate, object, timestamp FROM knowledge_graph ORDER BY timestamp DESC;"
        var statement: OpaquePointer?
        var facts: [FactItem] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                facts.append(factItem(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return facts
    }

    func fetchAllFacts(limit: Int) -> [FactItem] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, subject, predicate, object, timestamp
        FROM knowledge_graph ORDER BY timestamp DESC LIMIT ?;
        """
        var statement: OpaquePointer?
        var facts: [FactItem] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                facts.append(factItem(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return facts
    }

    func fetchAllFacts(limit: Int, offset: Int) -> [FactItem] {
        lock.lock()
        defer { lock.unlock() }
        let query = """
        SELECT id, subject, predicate, object, timestamp
        FROM knowledge_graph ORDER BY timestamp DESC LIMIT ? OFFSET ?;
        """
        var statement: OpaquePointer?
        var facts: [FactItem] = []
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            sqlite3_bind_int(statement, 2, Int32(offset))
            while sqlite3_step(statement) == SQLITE_ROW {
                facts.append(factItem(from: statement))
            }
        }
        sqlite3_finalize(statement)
        return facts
    }

    func countFacts() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM knowledge_graph;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return count
    }

    func deleteAllFacts() {
        lock.lock()
        defer { lock.unlock() }
        _ = sqlite3_exec(db, "DELETE FROM knowledge_graph;", nil, nil, nil)
    }

    func deleteFact(id: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let query = "DELETE FROM knowledge_graph WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func updateFact(id: Int64, subject: String, predicate: String, object: String) {
        lock.lock()
        defer { lock.unlock() }
        let query = "UPDATE knowledge_graph SET subject = ?, predicate = ?, object = ? WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (subject as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (predicate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (object as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 4, id)
            _ = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Row helpers

    private func chatEventItem(from statement: OpaquePointer?) -> ChatEventItem {
        let id = sqlite3_column_int64(statement, 0)
        let role = String(cString: sqlite3_column_text(statement, 1))
        let kind = String(cString: sqlite3_column_text(statement, 2))
        let title = String(cString: sqlite3_column_text(statement, 3))
        let detail = String(cString: sqlite3_column_text(statement, 4))
        let pinned = sqlite3_column_int(statement, 5) != 0
        let ts = Self.parseSQLiteTimestamp(String(cString: sqlite3_column_text(statement, 6))) ?? Date()
        return ChatEventItem(id: id, role: role, kind: kind, title: title, detail: detail, pinned: pinned, timestamp: ts)
    }

    private func factItem(from statement: OpaquePointer?) -> FactItem {
        let id = sqlite3_column_int64(statement, 0)
        let subject = String(cString: sqlite3_column_text(statement, 1))
        let predicate = String(cString: sqlite3_column_text(statement, 2))
        let object = String(cString: sqlite3_column_text(statement, 3))
        let ts = Self.parseSQLiteTimestamp(String(cString: sqlite3_column_text(statement, 4))) ?? Date()
        return FactItem(id: id, subject: subject, predicate: predicate, object: object, timestamp: ts)
    }
}
