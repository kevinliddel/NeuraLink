//
//  MemoryStore+Personas.swift
//  NeuraLink
//
//  SQL persistence for per-character AI personas: the `character_ai` table,
//  keyed by (character, engine). Each row carries the prompt + the
//  engine-appropriate voice (and a display name for the OpenAI row). Backs
//  PersonaStore, LocalLLMPromptStore, and PersonaVoiceStore — replacing their
//  JSON-file / UserDefaults "cache" persistence with SQL.
//
//  Engines: "openai" | "gemma_jp" | "local". Voice strings: OpenAI TTS voice
//  ("shimmer"), VoiceVox speaker id ("3"), or OpenVoice preset ("riko"). A
//  NULL prompt/voice means "use the built-in default" (the stores resolve it).
//
//  Methods are NSLock-guarded (mirrors MemoryStore+Queries.swift) and callable
//  off the main thread — the TTS engines resolve voices on background queues.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// Engine keys for the `character_ai` table.
    enum PersonaEngine {
        static let openai = "openai"
        /// JP-slot key. The stored value stays "gemma_jp" (the slot's former
        /// model) on purpose — it's a persisted DB key, so changing it would
        /// orphan users' existing JP persona prompts/voices. Only the Swift
        /// identifier was renamed to match the current model (LLM-jp-3).
        static let llmJp3 = "gemma_jp"
        static let local = "local"
    }

    // MARK: - Writes (per-column UPSERT)

    func setPersonaPrompt(character: String, engine: String, prompt: String?) {
        upsertPersonaColumn("prompt", character: character, engine: engine, value: prompt)
    }

    func setPersonaVoice(character: String, engine: String, voice: String?) {
        upsertPersonaColumn("voice", character: character, engine: engine, value: voice)
    }

    func setPersonaName(character: String, engine: String, name: String?) {
        upsertPersonaColumn("name", character: character, engine: engine, value: name)
    }

    // MARK: - Reads

    func personaPrompt(character: String, engine: String) -> String? {
        readPersonaColumn("prompt", character: character, engine: engine)
    }

    func personaVoice(character: String, engine: String) -> String? {
        readPersonaColumn("voice", character: character, engine: engine)
    }

    func personaName(character: String, engine: String) -> String? {
        readPersonaColumn("name", character: character, engine: engine)
    }

    // MARK: - Column helpers

    /// Sets a single column, preserving the row's other columns. `column` is a
    /// compile-time constant (never user input), so interpolating it is safe.
    ///
    /// UPDATE-then-INSERT rather than `INSERT … ON CONFLICT(character, engine)`:
    /// the upsert form requires a UNIQUE/PRIMARY-KEY index on (character, engine)
    /// to even *prepare*, and would silently no-op (writes lost — the persona
    /// prompt/voice never persists) if that constraint is ever absent on a
    /// device's existing `character_ai` table. This form persists regardless,
    /// and logs any failure instead of swallowing it. Serialized by `lock`, so
    /// the UPDATE→INSERT pair can't race into a duplicate row.
    private func upsertPersonaColumn(_ column: String, character: String, engine: String, value: String?) {
        lock.lock()
        defer { lock.unlock() }
        let key = character.lowercased()

        // 1. Update the existing row if present.
        var didUpdate = false
        let updateSQL = "UPDATE character_ai SET \(column) = ? WHERE character = ? AND engine = ?;"
        var update: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &update, nil) == SQLITE_OK {
            bindPersonaText(update, 1, value)
            bindPersonaText(update, 2, key)
            bindPersonaText(update, 3, engine)
            if sqlite3_step(update) == SQLITE_DONE {
                didUpdate = sqlite3_changes(db) > 0
            } else {
                nlLog("[MemoryStore] persona UPDATE \(column) step failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
            }
        } else {
            nlLog("[MemoryStore] persona UPDATE \(column) prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(update)
        if didUpdate { return }

        // 2. No existing row — insert a fresh one.
        let insertSQL = "INSERT INTO character_ai (character, engine, \(column)) VALUES (?, ?, ?);"
        var insert: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insert, nil) == SQLITE_OK {
            bindPersonaText(insert, 1, key)
            bindPersonaText(insert, 2, engine)
            bindPersonaText(insert, 3, value)
            if sqlite3_step(insert) != SQLITE_DONE {
                nlLog("[MemoryStore] persona INSERT \(column) step failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
            }
        } else {
            nlLog("[MemoryStore] persona INSERT \(column) prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(insert)
    }

    /// Binds `value` as text (TRANSIENT — SQLite copies it, so the temporary
    /// bridged string can't dangle before `step`), or NULL when nil.
    private func bindPersonaText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// SQLITE_TRANSIENT — tells SQLite to copy the bound bytes immediately.
    private static let sqliteTransient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self)

    /// Returns the column value, or nil when the row is missing OR the column is NULL.
    private func readPersonaColumn(_ column: String, character: String, engine: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT \(column) FROM character_ai WHERE character = ? AND engine = ?;"
        var statement: OpaquePointer?
        var result: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindPersonaText(statement, 1, character.lowercased())
            bindPersonaText(statement, 2, engine)
            if sqlite3_step(statement) == SQLITE_ROW,
               let c = sqlite3_column_text(statement, 0) {   // nil pointer if column is NULL
                result = String(cString: c)
            }
        } else {
            nlLog("[MemoryStore] persona SELECT \(column) prepare failed: \(String(cString: sqlite3_errmsg(db)!))", level: .warning)
        }
        sqlite3_finalize(statement)
        return result
    }

    // MARK: - Legacy migration

    /// One-shot import of per-character prompts/voices from the legacy
    /// PersonaStore (personas.json), LocalLLMPromptStore (local_llm_prompts.json),
    /// and PersonaVoiceStore (UserDefaults) into `character_ai`. Idempotent
    /// (UserDefaults-flagged). Legacy files/keys are left in place as a dormant
    /// backup.
    func migratePersonaStoresIfNeeded() {
        let flag = "com.neuralink.migration.personaStoresToSQL.v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }

        var imported = 0

        // 1. OpenAI personas (name + instructions + voice).
        if let personas = Self.loadLegacyPersonas() {
            for (character, persona) in personas {
                setPersonaName(character: character, engine: PersonaEngine.openai, name: persona.name)
                setPersonaPrompt(character: character, engine: PersonaEngine.openai, prompt: persona.instructions)
                setPersonaVoice(character: character, engine: PersonaEngine.openai, voice: persona.voice)
                imported += 1
            }
        }

        // 2. Local prompts (keys: "<char>" → local, "<char>_jp" → gemma_jp).
        if let prompts = Self.loadLegacyLocalPrompts() {
            for (key, prompt) in prompts {
                if key.hasSuffix("_jp") {
                    setPersonaPrompt(character: String(key.dropLast(3)), engine: PersonaEngine.llmJp3, prompt: prompt)
                } else {
                    setPersonaPrompt(character: key, engine: PersonaEngine.local, prompt: prompt)
                }
                imported += 1
            }
        }

        // 3. Voices (VoiceVox → gemma_jp, OpenVoice → local).
        if let voicevox = Self.loadLegacyDict(Int.self, key: "com.neuralink.tts.persona_voicevox_speaker_ids") {
            for (character, id) in voicevox {
                setPersonaVoice(character: character, engine: PersonaEngine.llmJp3, voice: String(id))
                imported += 1
            }
        }
        if let openVoice = Self.loadLegacyDict(String.self, key: "com.neuralink.tts.persona_openvoice_voice_presets") {
            for (character, preset) in openVoice {
                setPersonaVoice(character: character, engine: PersonaEngine.local, voice: preset)
                imported += 1
            }
        }

        defaults.set(true, forKey: flag)
        nlLog("[MemoryStore] Persona migration: imported \(imported) legacy entr(ies) into character_ai.", level: .info)
    }

    private static func loadLegacyPersonas() -> [String: CharacterPersona]? {
        if let dir = try? ProtectedStorage.privateApplicationSupportURL() {
            let url = dir.appendingPathComponent("personas.json")
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: data) {
                return decoded
            }
        }
        if let data = UserDefaults.standard.data(forKey: "com.neuralink.personas.v2.backup"),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: data) {
            return decoded
        }
        return nil
    }

    private static func loadLegacyLocalPrompts() -> [String: String]? {
        if let dir = try? ProtectedStorage.privateApplicationSupportURL() {
            let url = dir.appendingPathComponent("local_llm_prompts.json")
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                return decoded
            }
        }
        if let data = UserDefaults.standard.data(forKey: "com.neuralink.local-llm-prompts.v2.backup"),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }
        return nil
    }

    private static func loadLegacyDict<V: Decodable>(_ type: V.Type, key: String) -> [String: V]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: V].self, from: data)
        else { return nil }
        return decoded
    }
}
