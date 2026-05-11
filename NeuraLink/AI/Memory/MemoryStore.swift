//
//  MemoryStore.swift
//  NeuraLink
//
//  Manages local SQLite storage for AI memories.
//  Stores text chunks alongside their vector embeddings for similarity search.
//
//  Created by Antigravity on 09/05/2026.
//

import Foundation
import SQLite3

struct MemoryItem {
    let id: Int64
    let text: String
    let vector: [Double]
    let timestamp: Date
}

final class MemoryStore {
    static let shared = MemoryStore()
    
    private var db: OpaquePointer?
    private let dbPath: String
    
    private init() {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.dbPath = documentsURL.appendingPathComponent("neuralink_memory.sqlite").path
        
        setupDatabase()
    }
    
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
        """
        
        if sqlite3_exec(db, createTableQuery, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("[MemoryStore] Error creating tables: \(errmsg)")
        }
    }
    
    func insert(text: String, vector: [Double]) {
        let query = "INSERT INTO memories (text, vector) VALUES (?, ?);"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (text as NSString).utf8String, -1, nil)
            
            // Store vector as BLOB
            let data = Data(bytes: vector, count: vector.count * MemoryLayout<Double>.size)
            data.withUnsafeBytes { ptr in
                sqlite3_bind_blob(statement, 2, ptr.baseAddress, Int32(data.count), nil)
            }
            
            if sqlite3_step(statement) != SQLITE_DONE {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                print("[MemoryStore] Error inserting memory: \(errmsg)")
            }
        }
        sqlite3_finalize(statement)
    }
    
    func fetchAll() -> [MemoryItem] {
        let query = "SELECT id, text, vector, timestamp FROM memories ORDER BY timestamp DESC;"
        var statement: OpaquePointer?
        var items = [MemoryItem]()
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let text = String(cString: sqlite3_column_text(statement, 1))
                
                let blobPtr = sqlite3_column_blob(statement, 2)
                let blobSize = Int(sqlite3_column_bytes(statement, 2))
                let vectorCount = blobSize / MemoryLayout<Double>.size
                let vector = Array(UnsafeBufferPointer(start: blobPtr?.assumingMemoryBound(to: Double.self), count: vectorCount))
                
                // Simplified timestamp parsing (could be improved)
                let timestamp = Date() 
                
                items.append(MemoryItem(id: id, text: text, vector: vector, timestamp: timestamp))
            }
        }
        sqlite3_finalize(statement)
        return items
    }
    
    func clear() {
        let query1 = "DELETE FROM memories;"
        let query2 = "DELETE FROM knowledge_graph;"
        sqlite3_exec(db, query1, nil, nil, nil)
        sqlite3_exec(db, query2, nil, nil, nil)
    }

    // MARK: - Knowledge Graph
    
    func insertFact(subject: String, predicate: String, object: String) {
        let query = "INSERT INTO knowledge_graph (subject, predicate, object) VALUES (?, ?, ?);"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (subject as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (predicate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (object as NSString).utf8String, -1, nil)
            
            if sqlite3_step(statement) != SQLITE_DONE {
                let errmsg = String(cString: sqlite3_errmsg(db)!)
                print("[MemoryStore] Error inserting fact: \(errmsg)")
            }
        }
        sqlite3_finalize(statement)
    }
    
    func fetchAllFacts() -> [(String, String, String)] {
        let query = "SELECT subject, predicate, object FROM knowledge_graph;"
        var statement: OpaquePointer?
        var facts = [(String, String, String)]()
        
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let s = String(cString: sqlite3_column_text(statement, 0))
                let p = String(cString: sqlite3_column_text(statement, 1))
                let o = String(cString: sqlite3_column_text(statement, 2))
                facts.append((s, p, o))
            }
        }
        sqlite3_finalize(statement)
        return facts
    }
    
    deinit {
        sqlite3_close(db)
    }
}
