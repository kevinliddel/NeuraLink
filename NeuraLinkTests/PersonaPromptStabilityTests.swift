//
//  PersonaPromptStabilityTests.swift
//  NeuraLinkTests
//
//  Regression: saving a persona read back from PersonaStore must not grow the
//  prompt — the emotion preamble is re-applied on read and stripped on save.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("Persona prompt stability")
struct PersonaPromptStabilityTests {
    private let body = "You are Test, a cheerful companion.\nKeep replies short."

    @Test("Stripping removes stacked and legacy preambles and is idempotent")
    func strippingIsIdempotent() {
        let e = CharacterPersona.emotionInstructions
        #expect(CharacterPersona.strippingEmotionInstructions(body) == body)
        #expect(CharacterPersona.strippingEmotionInstructions(e + "\n" + body) == body)
        #expect(CharacterPersona.strippingEmotionInstructions(e + "\n" + e + "\n" + e + "\n" + body) == body)
        #expect(CharacterPersona.strippingEmotionInstructions(
            body + "\n\n    IMPORTANT: You MUST express feelings") == body)
    }

    @Test("withEmotionInstructions yields exactly one preamble")
    func singlePreamble() {
        let once = CharacterPersona.withEmotionInstructions(body)
        #expect(once == CharacterPersona.emotionInstructions + "\n" + body)
        #expect(CharacterPersona.withEmotionInstructions(once) == once)
    }

    @Test("Repeated save/load through PersonaStore does not grow the prompt")
    @MainActor
    func saveLoadRoundTripIsStable() {
        let slug = "test_persona_stability"
        let store = PersonaStore.shared
        store.resetPersona(for: slug)
        defer { store.resetPersona(for: slug) }

        var persona = CharacterPersona(
            name: "Stable", instructions: CharacterPersona.withEmotionInstructions(body), voice: "alloy")
        store.savePersona(persona, for: slug)
        let first = store.getPersona(for: slug)
        #expect(first?.instructions == CharacterPersona.emotionInstructions + "\n" + body)

        // The UI cycle: read back, save unchanged — five times.
        for _ in 0..<5 {
            persona = store.getPersona(for: slug)!
            store.savePersona(persona, for: slug)
        }
        #expect(store.getPersona(for: slug)?.instructions == first?.instructions)

        // SQL holds the clean body, never the preamble.
        let stored = MemoryStore.shared.personaPrompt(
            character: slug, engine: MemoryStore.PersonaEngine.openai)
        #expect(stored == body)
    }

    @Test("Rows stacked by the old bug are cleaned on read")
    @MainActor
    func legacyStackedRowsClean() {
        let slug = "test_persona_legacy_stack"
        let e = CharacterPersona.emotionInstructions
        MemoryStore.shared.setPersonaPrompt(
            character: slug, engine: MemoryStore.PersonaEngine.openai,
            prompt: e + "\n" + e + "\n" + e + "\n" + body)
        defer { PersonaStore.shared.resetPersona(for: slug) }
        #expect(PersonaStore.shared.getPersona(for: slug)?.instructions == e + "\n" + body)
    }
}
