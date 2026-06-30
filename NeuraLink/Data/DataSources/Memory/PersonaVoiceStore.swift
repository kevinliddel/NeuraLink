//
//  PersonaVoiceStore.swift
//  NeuraLink
//
//  Per-persona voice preference. Engine selection itself is automatic
//  (§3.1) — the user only picks WHICH voice (VOICEVOX speaker or OpenVoice
//  preset) to use for the persona.
//
//  VOICEVOX + OpenVoice voices are persisted in the `character_ai` SQL table
//  (MemoryStore+Personas.swift) alongside that engine's prompt — VOICEVOX
//  under engine "gemma_jp", OpenVoice under "local". The SQL `voice` column is
//  a string (the VOICEVOX speaker id is stored as text).
//
//  Created by Dedicatus on 26/05/2026.
//

import Foundation
import Observation

@Observable
@MainActor
final class PersonaVoiceStore {

    static let shared = PersonaVoiceStore()

    private init() {}

    // MARK: - VOICEVOX (engine "gemma_jp")

    /// Returns the user-chosen VOICEVOX speaker id for `persona`, or nil if the
    /// persona is using its built-in default (resolved by `VoiceVoxSpeaker.speakerID(for:)`).
    func voicevoxSpeakerID(for persona: PersonaIdentifier) -> Int? {
        MemoryStore.shared.personaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.llmJp3
        ).flatMap(Int.init)
    }

    /// Sets the VOICEVOX speaker for `persona`. Pass `nil` to clear the override.
    func setVoicevoxSpeakerID(_ id: Int?, for persona: PersonaIdentifier) {
        MemoryStore.shared.setPersonaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.llmJp3,
            voice: id.map(String.init))
    }

    func clearVoicevoxSpeakerID(for persona: PersonaIdentifier) {
        setVoicevoxSpeakerID(nil, for: persona)
    }

    // MARK: - OpenVoice (engine "local")

    func openVoiceVoiceID(for persona: PersonaIdentifier) -> String? {
        MemoryStore.shared.personaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.local)
    }

    func setOpenVoiceVoiceID(_ id: String?, for persona: PersonaIdentifier) {
        MemoryStore.shared.setPersonaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.local, voice: id)
    }

    func clearOpenVoiceVoiceID(for persona: PersonaIdentifier) {
        setOpenVoiceVoiceID(nil, for: persona)
    }

    // MARK: - Nonisolated reads (engines on background queues)

    /// Thread-safe read for callers in nonisolated contexts. SQL access is
    /// guarded by MemoryStore's NSLock. `String` rather than `PersonaIdentifier`
    /// because the typealias is MainActor-isolated and not visible here.
    nonisolated static func voicevoxSpeakerIDFromDefaults(for persona: String) -> Int? {
        MemoryStore.shared.personaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.llmJp3
        ).flatMap(Int.init)
    }

    nonisolated static func openVoiceVoiceIDFromDefaults(for persona: String) -> String? {
        MemoryStore.shared.personaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.local)
    }
}
