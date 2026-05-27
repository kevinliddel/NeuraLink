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
///    only if the file is missing/unreadable on a fresh process. Solves the
///    "still not persisting" report where the file path or protection class
///    was preventing the file read from succeeding.
@Observable
final class PersonaStore {
    static let shared = PersonaStore()

    /// Bumped on every save/reset. Views observing this property re-render.
    var lastUpdated = Date()

    private let userDefaults = UserDefaults.standard
    private let legacyCacheKey = "com.neuralink.personas.v1"
    /// Same payload as the legacy key, but kept up-to-date as a backup for the
    /// file storage. Distinct name so the old legacy migration path stays a
    /// one-shot operation.
    private let backupCacheKey = "com.neuralink.personas.v2.backup"

    /// Authoritative in-memory copy. The file on disk + UserDefaults backup
    /// are the durable layers; callers always read from this cache so
    /// concurrent saves and reads can't race on a partially-rewritten file.
    @ObservationIgnored private var cachedPersonas: [String: CharacterPersona] = [:]

    private var fileURL: URL? {
        do {
            let dir = try ProtectedStorage.privateApplicationSupportURL()
            return dir.appendingPathComponent("personas.json")
        } catch {
            nlLog("[PersonaStore] Failed to resolve secure private storage directory: \(error)", level: .error)
            return nil
        }
    }

    private init() {
        cachedPersonas = loadInitialPersonas()
        nlLog("[PersonaStore] Initialized with \(cachedPersonas.count) saved persona(s).", level: .info)
    }

    // MARK: - Public API

    /// Saves a persona for a given model ID (usually the filename).
    func savePersona(_ persona: CharacterPersona, for modelID: String) {
        let key = modelID.lowercased()
        var updated = cachedPersonas
        updated[key] = persona
        cachedPersonas = updated
        lastUpdated = Date()
        nlLog("[PersonaStore] Saving persona for '\(key)' (voice=\(persona.voice), instructions length=\(persona.instructions.count))", level: .info)
        flushToBothLayers()
    }

    /// Retrieves a cached persona for a given model ID.
    /// Always injects the latest emotion instructions to override any stale cached data.
    func getPersona(for modelID: String) -> CharacterPersona? {
        guard var persona = cachedPersonas[modelID.lowercased()] else { return nil }
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
        var updated = cachedPersonas
        updated.removeValue(forKey: key)
        cachedPersonas = updated
        lastUpdated = Date()
        nlLog("[PersonaStore] Reset persona for '\(key)'", level: .info)
        flushToBothLayers()
    }

    // MARK: - Disk I/O

    /// File first, then UserDefaults backup, then legacy migration. Returns
    /// `[:]` only when every layer is empty / unreadable.
    private func loadInitialPersonas() -> [String: CharacterPersona] {
        // Layer 1 — protected file.
        if let url = fileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: data) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from \(url.path)", level: .info)
            return decoded
        }

        // Layer 2 — UserDefaults backup written on every save.
        if let backupData = userDefaults.data(forKey: backupCacheKey),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: backupData) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from UserDefaults backup (file layer missing/unreadable).", level: .info)
            return decoded
        }

        // Layer 3 — legacy UserDefaults key (one-shot, kept for migrations).
        if let legacyData = userDefaults.data(forKey: legacyCacheKey),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: legacyData) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from legacy UserDefaults key.", level: .info)
            // Promote to the file + backup layers so the legacy key can be retired.
            userDefaults.set(legacyData, forKey: backupCacheKey)
            if let url = fileURL {
                _ = try? legacyData.write(to: url, options: .atomic)
                try? ProtectedStorage.protect(url)
            }
            userDefaults.removeObject(forKey: legacyCacheKey)
            return decoded
        }

        nlLog("[PersonaStore] No saved personas found — starting fresh.", level: .info)
        return [:]
    }

    /// Writes the in-memory cache to both the protected file and the
    /// UserDefaults backup. Each layer fails independently — if one breaks,
    /// the other keeps the data alive across restarts.
    private func flushToBothLayers() {
        guard let encoded = try? JSONEncoder().encode(cachedPersonas) else {
            nlLog("[PersonaStore] flushToBothLayers: failed to encode \(cachedPersonas.count) persona(s).", level: .error)
            return
        }

        // Layer 1 — protected file
        if let url = fileURL {
            do {
                try encoded.write(to: url, options: .atomic)
                try? ProtectedStorage.protect(url)
                nlLog("[PersonaStore] flushToBothLayers: wrote \(encoded.count) bytes to \(url.lastPathComponent)", level: .info)
            } catch {
                nlLog("[PersonaStore] flushToBothLayers: file write failed: \(error)", level: .error)
            }
        } else {
            nlLog("[PersonaStore] flushToBothLayers: no fileURL — file layer skipped.", level: .error)
        }

        // Layer 2 — UserDefaults backup (always attempted, independent of file)
        userDefaults.set(encoded, forKey: backupCacheKey)
    }
}
