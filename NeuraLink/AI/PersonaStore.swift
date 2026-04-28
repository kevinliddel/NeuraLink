//
//  PersonaStore.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation
import Observation

/// Manages persistent storage of character personas using UserDefaults.
@Observable
final class PersonaStore {
    static let shared = PersonaStore()
    
    // This property is what the UI will observe
    var lastUpdated = Date()
    private let userDefaults = UserDefaults.standard
    private let cacheKey = "com.neuralink.personas.v1"

    private init() {}

    /// Saves a persona for a given model ID (usually the filename).
    func savePersona(_ persona: CharacterPersona, for modelID: String) {
        var allPersonas = getAllPersonas()
        allPersonas[modelID.lowercased()] = persona
        
        if let encoded = try? JSONEncoder().encode(allPersonas) {
            userDefaults.set(encoded, forKey: cacheKey)
            lastUpdated = Date()
            print("[PersonaStore] Saved persona for \(modelID)")
        }
    }

    /// Retrieves a cached persona for a given model ID.
    func getPersona(for modelID: String) -> CharacterPersona? {
        return getAllPersonas()[modelID.lowercased()]
    }

    /// Removes any custom persona for a given model ID, reverting to defaults.
    func resetPersona(for modelID: String) {
        var allPersonas = getAllPersonas()
        allPersonas.removeValue(forKey: modelID.lowercased())
        
        if let encoded = try? JSONEncoder().encode(allPersonas) {
            userDefaults.set(encoded, forKey: cacheKey)
            lastUpdated = Date()
            print("[PersonaStore] Reset persona for \(modelID)")
        }
    }

    private func getAllPersonas() -> [String: CharacterPersona] {
        guard let data = userDefaults.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: CharacterPersona].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
