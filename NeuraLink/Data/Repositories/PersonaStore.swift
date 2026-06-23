//
//  PersonaStore.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation
import Observation

/// Manages persistent storage of OpenAI character personas.
///
/// Backed by the `character_ai` SQL table (MemoryStore+Personas.swift), engine
/// "openai" — the row's `name`/`prompt`/`voice` columns hold the persona's
/// display name, instructions, and OpenAI TTS voice. `lastUpdated` is bumped on
/// every save/reset so observing views (AISettings) re-render.
@Observable
@MainActor
final class PersonaStore {
    static let shared = PersonaStore()

    /// Bumped on every save/reset. Views observing this property re-render.
    var lastUpdated = Date()

    private static let engine = MemoryStore.PersonaEngine.openai

    private init() {}

    // MARK: - Public API

    /// Saves a persona for a given model ID (usually the filename).
    func savePersona(_ persona: CharacterPersona, for modelID: String) {
        let key = modelID.lowercased()
        MemoryStore.shared.setPersonaName(character: key, engine: Self.engine, name: persona.name)
        MemoryStore.shared.setPersonaPrompt(character: key, engine: Self.engine, prompt: persona.instructions)
        MemoryStore.shared.setPersonaVoice(character: key, engine: Self.engine, voice: persona.voice)
        nlLog("[PersonaStore] Saving persona for '\(key)' (voice=\(persona.voice), instructions length=\(persona.instructions.count))", level: .info)
        lastUpdated = Date()
    }

    /// Retrieves the stored persona for a model ID, or nil when none is saved
    /// (so `CharacterPersona.forCharacter` falls back to the built-in default).
    /// Always injects the latest emotion instructions to override any stale data.
    func getPersona(for modelID: String) -> CharacterPersona? {
        let key = modelID.lowercased()
        guard let prompt = MemoryStore.shared.personaPrompt(character: key, engine: Self.engine) else {
            return nil
        }
        let name = MemoryStore.shared.personaName(character: key, engine: Self.engine) ?? modelID.capitalized
        let voice = MemoryStore.shared.personaVoice(character: key, engine: Self.engine) ?? "alloy"
        var persona = CharacterPersona(name: name, instructions: prompt, voice: voice)

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
        MemoryStore.shared.setPersonaName(character: key, engine: Self.engine, name: nil)
        MemoryStore.shared.setPersonaPrompt(character: key, engine: Self.engine, prompt: nil)
        MemoryStore.shared.setPersonaVoice(character: key, engine: Self.engine, voice: nil)
        nlLog("[PersonaStore] Reset persona for '\(key)'", level: .info)
        lastUpdated = Date()
    }
}
