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
//  a string (the VOICEVOX speaker id is stored as text). Kokoro is being
//  retired and keeps its UserDefaults map untouched.
//
//  Created by Dedicatus on 26/05/2026.
//

import Foundation
import Observation

@Observable
@MainActor
final class PersonaVoiceStore {

    static let shared = PersonaVoiceStore()

    /// Kokoro is the only remaining UserDefaults-backed map (slated for removal).
    private(set) var kokoroVoicePresets: [PersonaIdentifier: String]

    nonisolated static let kokoroDefaultsKey = "com.neuralink.tts.persona_kokoro_voice_presets"

    private init() {
        kokoroVoicePresets = PersonaVoiceStore.loadKokoroFromDefaults()
    }

    // MARK: - VOICEVOX (engine "gemma_jp")

    /// Returns the user-chosen VOICEVOX speaker id for `persona`, or nil if the
    /// persona is using its built-in default (resolved by `VoiceVoxSpeaker.speakerID(for:)`).
    func voicevoxSpeakerID(for persona: PersonaIdentifier) -> Int? {
        MemoryStore.shared.personaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.gemmaJP
        ).flatMap(Int.init)
    }

    /// Sets the VOICEVOX speaker for `persona`. Pass `nil` to clear the override.
    func setVoicevoxSpeakerID(_ id: Int?, for persona: PersonaIdentifier) {
        MemoryStore.shared.setPersonaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.gemmaJP,
            voice: id.map(String.init))
    }

    func clearVoicevoxSpeakerID(for persona: PersonaIdentifier) {
        setVoicevoxSpeakerID(nil, for: persona)
    }

    // MARK: - Kokoro (legacy, UserDefaults)

    func kokoroVoiceID(for persona: PersonaIdentifier) -> String? {
        kokoroVoicePresets[persona.lowercased()]
    }

    func setKokoroVoiceID(_ id: String?, for persona: PersonaIdentifier) {
        let key = persona.lowercased()
        if let id {
            kokoroVoicePresets[key] = id
        } else {
            kokoroVoicePresets.removeValue(forKey: key)
        }
        persistKokoro()
    }

    func clearKokoroVoiceID(for persona: PersonaIdentifier) {
        setKokoroVoiceID(nil, for: persona)
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
            character: persona, engine: MemoryStore.PersonaEngine.gemmaJP
        ).flatMap(Int.init)
    }

    nonisolated static func openVoiceVoiceIDFromDefaults(for persona: String) -> String? {
        MemoryStore.shared.personaVoice(
            character: persona, engine: MemoryStore.PersonaEngine.local)
    }

    nonisolated static func kokoroVoiceIDFromDefaults(for persona: String) -> String? {
        loadKokoroFromDefaults()[persona.lowercased()]
    }

    // MARK: - Kokoro persistence

    private nonisolated static func loadKokoroFromDefaults() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: kokoroDefaultsKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persistKokoro() {
        guard let data = try? JSONEncoder().encode(kokoroVoicePresets) else { return }
        UserDefaults.standard.set(data, forKey: PersonaVoiceStore.kokoroDefaultsKey)
    }
}
