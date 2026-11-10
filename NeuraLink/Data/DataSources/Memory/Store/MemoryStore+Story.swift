//
//  MemoryStore+Story.swift
//  NeuraLink
//
//  The character's own side of memory — Inner life
//  (docs/Companion/LIVING_COMPANION.md). `companion_self_facts`: things a
//  character has said about its own life, kept so it stays consistent with
//  itself. `character_story`: the generated, user-editable story sheet of
//  an imported character, one row per line (kind + position). Mirrors the
//  prepared-statement + NSLock style of MemoryStore+Lore.swift.
//
//  Created by Dedicatus on 10/11/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// The most a character keeps of what it said about itself; the oldest go first.
    static let selfFactCap = 40

    // MARK: - What the character said about itself

    /// Keeps `text` for `character` (a repeat is ignored) and trims the
    /// pool to the newest `selfFactCap`.
    func addSelfFact(character: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        runStory("INSERT OR IGNORE INTO companion_self_facts (character, text) VALUES (?, ?);", texts: [character, text])
        runStory(
            """
            DELETE FROM companion_self_facts WHERE character = ? AND id NOT IN (
                SELECT id FROM companion_self_facts WHERE character = ? ORDER BY id DESC LIMIT \(Self.selfFactCap));
            """, texts: [character, character])
    }

    /// What a character has said about itself, newest first.
    func selfFacts(character: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var items: [String] = []
        let query = "SELECT text FROM companion_self_facts WHERE character = ? ORDER BY id DESC;"
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) { items.append(String(cString: text)) }
            }
        }
        sqlite3_finalize(statement)
        return items
    }

    /// Forgets what a character said about itself ("Reset personality").
    func deleteSelfFacts(character: String) {
        lock.lock()
        defer { lock.unlock() }
        runStory("DELETE FROM companion_self_facts WHERE character = ?;", texts: [character])
    }

    // MARK: - An imported character's story sheet

    /// Every line of a character's stored sheet as (kind, text), in
    /// position order within each kind.
    func storyRows(character: String) -> [(kind: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var rows: [(kind: String, text: String)] = []
        let query = "SELECT kind, text FROM character_story WHERE character = ? ORDER BY kind, position;"
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character.lowercased() as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else { continue }
                rows.append((String(cString: kind), String(cString: text)))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    /// Replaces a character's stored sheet with `rows`; positions follow
    /// the order given within each kind.
    func replaceStory(character: String, rows: [(kind: String, text: String)]) {
        lock.lock()
        defer { lock.unlock() }
        let key = character.lowercased()
        runStory("DELETE FROM character_story WHERE character = ?;", texts: [key])
        var positions: [String: Int] = [:]
        for row in rows {
            let position = positions[row.kind, default: 0]
            positions[row.kind] = position + 1
            runStory(
                "INSERT INTO character_story (character, kind, position, text) VALUES (?, ?, \(position), ?);",
                texts: [key, row.kind, row.text])
        }
    }

    /// Removes a character's stored sheet (the character was deleted).
    func deleteStory(character: String) {
        lock.lock()
        defer { lock.unlock() }
        runStory("DELETE FROM character_story WHERE character = ?;", texts: [character.lowercased()])
    }

    /// One statement with text bindings; the caller holds the lock.
    private func runStory(_ query: String, texts: [String]) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            for (index, text) in texts.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), (text as NSString).utf8String, -1, nil)
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                nlLog("[MemoryStore] Story statement failed: \(String(cString: sqlite3_errmsg(db)!))", level: .info)
            }
        }
        sqlite3_finalize(statement)
    }
}
