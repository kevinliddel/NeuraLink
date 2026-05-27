//
//  PersonaStore.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation
import Observation

/// Manages persistent storage of character personas.
///
/// **Persistence layers (belt-and-suspenders):**
/// 1. **In-memory cache** — authoritative source of truth for reads. Updated
///    synchronously on every save so a fresh `PersonaSettingsView` instance
///    immediately sees the user's edits.
/// 2. **JSON file** in `Application Support/private/` — durable backup with
///    Data Protection applied. Survives app restarts.
/// 3. **UserDefaults JSON blob** — secondary durable backup. Restored from
///    only if the file is missing/unreadable on a fresh process.
///
/// **Why the storage class is split off:** Earlier revisions kept `cachedPersonas`
/// as a property of this `@Observable` class with `@ObservationIgnored`. Under
/// Xcode 26 / Swift 6.2 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, that
/// combination produced a reproducible bug where the dictionary appeared to
/// reset to `[:]` between two consecutive calls to `flushToBothLayers` on
/// the same instance — wiping the file moments after a successful save.
/// Moving the dict into a non-`@Observable` `PersonaCacheStorage` class
/// makes mutations deterministic. The outer `@Observable` shell still owns
/// `lastUpdated` so `AISettingsView`'s `_ = personaStore.lastUpdated` re-render
/// trigger keeps working.
@Observable
@MainActor
final class PersonaStore {
    static let shared = PersonaStore()

    /// Bumped on every save/reset. Views observing this property re-render.
    var lastUpdated = Date()

    @ObservationIgnored
    private let storage = PersonaCacheStorage()

    private init() {
        storage.loadFromDisk()
        nlLog("[PersonaStore] Initialized with \(storage.count) saved persona(s).", level: .info)
    }

    // MARK: - Public API

    /// Saves a persona for a given model ID (usually the filename).
    func savePersona(_ persona: CharacterPersona, for modelID: String) {
        let key = modelID.lowercased()
        storage.upsert(persona, forKey: key)
        nlLog("[PersonaStore] Saving persona for '\(key)' (voice=\(persona.voice), instructions length=\(persona.instructions.count))", level: .info)
        lastUpdated = Date()
    }

    /// Retrieves a cached persona for a given model ID.
    /// Always injects the latest emotion instructions to override any stale cached data.
    func getPersona(for modelID: String) -> CharacterPersona? {
        let key = modelID.lowercased()
        guard var persona = storage.get(forKey: key) else {
            nlLog("[PersonaStore] getPersona('\(key)') → NIL (cache keys: \(storage.allKeys))", level: .info)
            return nil
        }
        nlLog("[PersonaStore] getPersona('\(key)') → SAVED (voice=\(persona.voice))", level: .info)
        let marker = "\n\n    IMPORTANT: You MUST express"
        if let range = persona.instructions.range(of: marker) {
            persona.instructions = String(persona.instructions[..<range.lowerBound])
        }
        persona.instructions = CharacterPersona.emotionInstructions + "\n" + persona.instructions
        return persona
    }

    /// Removes any custom persona for a given model ID, reverting to defaults.
    func resetPersona(for modelID: String) {
        let key = modelID.lowercased()
        storage.remove(forKey: key)
        nlLog("[PersonaStore] Reset persona for '\(key)'", level: .info)
        lastUpdated = Date()
    }
}

// MARK: - Storage (non-Observable, owns the durable layers)

/// Plain class that holds the in-memory dict + handles file & UserDefaults
/// persistence. Kept separate from `PersonaStore` so the `@Observable` macro
/// never touches its stored properties — see PersonaStore's class-level doc
/// comment for the bug this isolation fixes.
@MainActor
private final class PersonaCacheStorage {
    private var cache: [String: CharacterPersona] = [:]

    private let userDefaults = UserDefaults.standard
    private let legacyCacheKey = "com.neuralink.personas.v1"
    private let backupCacheKey = "com.neuralink.personas.v2.backup"

    private var fileURL: URL? {
        do {
            let dir = try ProtectedStorage.privateApplicationSupportURL()
            return dir.appendingPathComponent("personas.json")
        } catch {
            nlLog("[PersonaStore] Failed to resolve secure private storage directory: \(error)", level: .error)
            return nil
        }
    }

    var count: Int { cache.count }
    var allKeys: [String] { cache.keys.sorted() }

    func get(forKey key: String) -> CharacterPersona? {
        cache[key]
    }

    func upsert(_ persona: CharacterPersona, forKey key: String) {
        cache[key] = persona
        flushToBothLayers()
    }

    func remove(forKey key: String) {
        cache.removeValue(forKey: key)
        flushToBothLayers()
    }

    /// File first, then UserDefaults backup, then legacy migration.
    func loadFromDisk() {
        if let url = fileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: data) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from \(url.path)", level: .info)
            cache = decoded
            return
        }

        if let backupData = userDefaults.data(forKey: backupCacheKey),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: backupData) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from UserDefaults backup.", level: .info)
            cache = decoded
            return
        }

        if let legacyData = userDefaults.data(forKey: legacyCacheKey),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: legacyData) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from legacy UserDefaults key.", level: .info)
            userDefaults.set(legacyData, forKey: backupCacheKey)
            if let url = fileURL {
                _ = try? legacyData.write(to: url, options: .atomic)
                try? ProtectedStorage.protect(url)
            }
            userDefaults.removeObject(forKey: legacyCacheKey)
            cache = decoded
            return
        }

        nlLog("[PersonaStore] No saved personas found — starting fresh.", level: .info)
        cache = [:]
    }

    private func flushToBothLayers() {
        guard let encoded = try? JSONEncoder().encode(cache) else {
            nlLog("[PersonaStore] flushToBothLayers: failed to encode \(cache.count) persona(s).", level: .error)
            return
        }
        if let url = fileURL {
            do {
                try encoded.write(to: url, options: .atomic)
                try? ProtectedStorage.protect(url)
                nlLog("[PersonaStore] flushToBothLayers: wrote \(encoded.count) bytes to \(url.lastPathComponent) (cache size: \(cache.count))", level: .info)
            } catch {
                nlLog("[PersonaStore] flushToBothLayers: file write failed: \(error)", level: .error)
            }
        } else {
            nlLog("[PersonaStore] flushToBothLayers: no fileURL — file layer skipped.", level: .error)
        }
        userDefaults.set(encoded, forKey: backupCacheKey)
    }
}
