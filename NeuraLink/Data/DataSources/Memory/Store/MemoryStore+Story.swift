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

    /// One stored line of a sheet. `fragmentID` is a story's own id ("" for
    /// the other kinds and for rows written before stories had one).
    struct StoryRow: Equatable, Sendable {
        var kind: String
        var text: String
        var fragmentID: String = ""
    }

    /// Every line of a character's stored sheet, in position order within
    /// each kind.
    func storyRows(character: String) -> [StoryRow] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var rows: [StoryRow] = []
        let query = "SELECT kind, text, fragment_id FROM character_story WHERE character = ? ORDER BY kind, position;"
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (character.lowercased() as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kind = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else { continue }
                let id = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                rows.append(StoryRow(kind: String(cString: kind), text: String(cString: text), fragmentID: id))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    /// Replaces a character's stored sheet with `rows`, all or nothing:
    /// one transaction, rolled back when any statement fails, so a crash or
    /// an error never leaves half a sheet. Positions follow the order given
    /// within each kind. Returns false when nothing was changed.
    @discardableResult
    func replaceStory(character: String, rows: [StoryRow]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
        let key = character.lowercased()
        var done = runStory("DELETE FROM character_story WHERE character = ?;", texts: [key])
        var positions: [String: Int] = [:]
        for row in rows where done {
            let position = positions[row.kind, default: 0]
            positions[row.kind] = position + 1
            done = runStory(
                "INSERT INTO character_story (character, kind, position, text, fragment_id) VALUES (?, ?, \(position), ?, ?);",
                texts: [key, row.kind, row.text, row.fragmentID])
        }
        _ = sqlite3_exec(db, done ? "COMMIT;" : "ROLLBACK;", nil, nil, nil)
        return done
    }

    /// Removes a character's stored sheet (the character was deleted).
    func deleteStory(character: String) {
        lock.lock()
        defer { lock.unlock() }
        runStory("DELETE FROM character_story WHERE character = ?;", texts: [character.lowercased()])
    }

    /// One statement with text bindings; the caller holds the lock.
    /// False when it could not be prepared or did not run to completion.
    @discardableResult
    private func runStory(_ query: String, texts: [String]) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            nlLog("[MemoryStore] Story statement not prepared: \(String(cString: sqlite3_errmsg(db)!))", level: .info)
            return false
        }
        for (index, text) in texts.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), (text as NSString).utf8String, -1, nil)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            nlLog("[MemoryStore] Story statement failed: \(String(cString: sqlite3_errmsg(db)!))", level: .info)
            return false
        }
        return true
    }
}
