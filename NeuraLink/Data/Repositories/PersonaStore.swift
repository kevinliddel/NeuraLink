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
@Observable
@MainActor
final class PersonaStore {
    static let shared = PersonaStore()

    /// Bumped on every save/reset. Views observing this property re-render.
    var lastUpdated = Date()

    @ObservationIgnored private var cachedPersonas: [String: CharacterPersona] = [:]
    @ObservationIgnored private let userDefaults = UserDefaults.standard
    @ObservationIgnored private let legacyCacheKey = "com.neuralink.personas.v1"
    @ObservationIgnored private let backupCacheKey = "com.neuralink.personas.v2.backup"

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
        cachedPersonas[key] = persona
        nlLog("[PersonaStore] Saving persona for '\(key)' (voice=\(persona.voice), instructions length=\(persona.instructions.count))", level: .info)
        flushToBothLayers()
        lastUpdated = Date()
    }

    /// Retrieves a cached persona for a given model ID.
    /// Always injects the latest emotion instructions to override any stale cached data.
    func getPersona(for modelID: String) -> CharacterPersona? {
        let key = modelID.lowercased()
        guard var persona = cachedPersonas[key] else {
            nlLog("[PersonaStore] getPersona('\(key)') → NIL (cache keys: \(Array(cachedPersonas.keys).sorted()))", level: .info)
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
        cachedPersonas.removeValue(forKey: key)
        nlLog("[PersonaStore] Reset persona for '\(key)'", level: .info)
        flushToBothLayers()
        lastUpdated = Date()
    }

    // MARK: - Disk I/O

    private func loadInitialPersonas() -> [String: CharacterPersona] {
        if let url = fileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: data) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from \(url.path)", level: .info)
            return decoded
        }

        if let backupData = userDefaults.data(forKey: backupCacheKey),
           let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: backupData) {
            nlLog("[PersonaStore] Loaded \(decoded.count) persona(s) from UserDefaults backup.", level: .info)
            return decoded
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
            return decoded
        }

        nlLog("[PersonaStore] No saved personas found — starting fresh.", level: .info)
        return [:]
    }

    private func flushToBothLayers() {
        guard let encoded = try? JSONEncoder().encode(cachedPersonas) else {
            nlLog("[PersonaStore] flushToBothLayers: failed to encode \(cachedPersonas.count) persona(s).", level: .error)
            return
        }
        if let url = fileURL {
            do {
                try encoded.write(to: url, options: .atomic)
                try? ProtectedStorage.protect(url)
                nlLog("[PersonaStore] flushToBothLayers: wrote \(encoded.count) bytes to \(url.lastPathComponent) (cache size: \(cachedPersonas.count))", level: .info)
            } catch {
                nlLog("[PersonaStore] flushToBothLayers: file write failed: \(error)", level: .error)
            }
        } else {
            nlLog("[PersonaStore] flushToBothLayers: no fileURL — file layer skipped.", level: .error)
        }
        userDefaults.set(encoded, forKey: backupCacheKey)
    }
}
