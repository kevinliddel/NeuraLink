//
//  PersonaStore.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation
import Observation

/// Manages persistent storage of character personas using a protected JSON file.
@Observable
final class PersonaStore {
    static let shared = PersonaStore()
    
    // This property is what the UI will observe
    var lastUpdated = Date()
    private let userDefaults = UserDefaults.standard
    private let cacheKey = "com.neuralink.personas.v1"

    private var fileURL: URL? {
        do {
            let dir = try ProtectedStorage.privateApplicationSupportURL()
            return dir.appendingPathComponent("personas.json")
        } catch {
            nlLog("[PersonaStore] Failed to resolve secure private storage directory: \(error)", level: .error)
            return nil
        }
    }

    private init() {}

    /// Saves a persona for a given model ID (usually the filename).
    func savePersona(_ persona: CharacterPersona, for modelID: String) {
        var allPersonas = getAllPersonas()
        allPersonas[modelID.lowercased()] = persona
        
        guard let url = fileURL else { return }
        
        if let encoded = try? JSONEncoder().encode(allPersonas) {
            do {
                try encoded.write(to: url, options: .atomic)
                try ProtectedStorage.protect(url)
                lastUpdated = Date()
                nlLog("[PersonaStore] Saved persona for \(modelID) to secure storage", level: .info)
            } catch {
                nlLog("[PersonaStore] Failed to write secure persona file: \(error)", level: .error)
            }
        }
    }

    /// Retrieves a cached persona for a given model ID.
    /// Always injects the latest emotion instructions to override any stale cached data.
    func getPersona(for modelID: String) -> CharacterPersona? {
        guard var persona = getAllPersonas()[modelID.lowercased()] else { return nil }
        // Strip any previously persisted emotion instructions block, then re-inject
        // the current one at the top so format changes are always applied.
        let marker = "\n\n    IMPORTANT: You MUST express"
        if let range = persona.instructions.range(of: marker) {
            persona.instructions = String(persona.instructions[..<range.lowerBound])
        }
        persona.instructions = CharacterPersona.emotionInstructions + "\n" + persona.instructions
        return persona
    }

    /// Removes any custom persona for a given model ID, reverting to defaults.
    func resetPersona(for modelID: String) {
        var allPersonas = getAllPersonas()
        allPersonas.removeValue(forKey: modelID.lowercased())
        
        guard let url = fileURL else { return }
        
        if let encoded = try? JSONEncoder().encode(allPersonas) {
            do {
                try encoded.write(to: url, options: .atomic)
                try ProtectedStorage.protect(url)
                lastUpdated = Date()
                nlLog("[PersonaStore] Reset persona for \(modelID) in secure storage", level: .info)
            } catch {
                nlLog("[PersonaStore] Failed to write secure persona file during reset: \(error)", level: .error)
            }
        }
    }

    private func getAllPersonas() -> [String: CharacterPersona] {
        guard let url = fileURL else { return [:] }
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: url.path) {
            // Perform one-shot migration if legacy UserDefaults data is found
            if let legacyData = userDefaults.data(forKey: cacheKey) {
                nlLog("[PersonaStore] Migrating legacy personas from UserDefaults to secure file storage...", level: .info)
                do {
                    try legacyData.write(to: url, options: .atomic)
                    try ProtectedStorage.protect(url)
                    userDefaults.removeObject(forKey: cacheKey)
                    nlLog("[PersonaStore] Migration successful. Erased legacy UserDefaults key.", level: .info)
                    if let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: legacyData) {
                        return decoded
                    }
                } catch {
                    nlLog("[PersonaStore] Migration failed to write secure file: \(error)", level: .error)
                }
            }
            return [:]
        }
        
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: data) else {
            nlLog("[PersonaStore] Failed to read or decode personas from \(url.path)", level: .error)
            return [:]
        }
        return decoded
    }
}
