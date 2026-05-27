//
//  PersonaVoiceStore.swift
//  NeuraLink
//
//  Per-persona voice preference. Engine selection itself is automatic
//  (§3.1) — the user only picks WHICH voice (VOICEVOX speaker or Kokoro
//  preset) to use for the persona. Other engines (System, F5-TTS) infer
//  their voice from the persona name + device locale and don't need
//  overrides.
//
//  Persists each map in UserDefaults as a JSON-encoded dictionary.
//
//  Created by Dedicatus on 26/05/2026.
//

import Foundation
import Observation

@Observable
@MainActor
final class PersonaVoiceStore {

    static let shared = PersonaVoiceStore()

    private(set) var voicevoxSpeakerIDs: [PersonaIdentifier: Int]
    private(set) var kokoroVoicePresets: [PersonaIdentifier: String]

    nonisolated static let defaultsKey = "com.neuralink.tts.persona_voicevox_speaker_ids"
    nonisolated static let kokoroDefaultsKey = "com.neuralink.tts.persona_kokoro_voice_presets"

    private init() {
        voicevoxSpeakerIDs = PersonaVoiceStore.loadFromDefaults()
        kokoroVoicePresets = PersonaVoiceStore.loadKokoroFromDefaults()
    }

    // MARK: - VOICEVOX

    /// Returns the user-chosen VOICEVOX speaker filename ID for `persona`,
    /// or nil if the persona is using its built-in default
    /// (resolved by `VoiceVoxSpeaker.speakerID(for:)`).
    func voicevoxSpeakerID(for persona: PersonaIdentifier) -> Int? {
        voicevoxSpeakerIDs[persona.lowercased()]
    }

    /// Sets the VOICEVOX speaker for `persona`. Pass `nil` to clear the
    /// override and revert to the built-in default.
    func setVoicevoxSpeakerID(_ id: Int?, for persona: PersonaIdentifier) {
        let key = persona.lowercased()
        if let id {
            voicevoxSpeakerIDs[key] = id
        } else {
            voicevoxSpeakerIDs.removeValue(forKey: key)
        }
        persist()
    }

    /// Clears the override for `persona`.
    func clearVoicevoxSpeakerID(for persona: PersonaIdentifier) {
        setVoicevoxSpeakerID(nil, for: persona)
    }

    // MARK: - Kokoro

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

    // MARK: - Nonisolated reads

    /// Thread-safe direct UserDefaults read for callers in nonisolated
    /// contexts (engines on background queues). Returns the current
    /// override or nil. Bypasses the @Observable in-memory cache by design.
    ///
    /// `String` rather than `PersonaIdentifier` here because the typealias
    /// is MainActor-isolated by the project's default-isolation setting
    /// and isn't visible from `nonisolated` scopes.
    nonisolated static func voicevoxSpeakerIDFromDefaults(
        for persona: String
    ) -> Int? {
        loadFromDefaults()[persona.lowercased()]
    }

    nonisolated static func kokoroVoiceIDFromDefaults(
        for persona: String
    ) -> String? {
        loadKokoroFromDefaults()[persona.lowercased()]
    }

    private nonisolated static func loadFromDefaults() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(
                [String: Int].self, from: data
            )
        else { return [:] }
        return decoded
    }

    private nonisolated static func loadKokoroFromDefaults() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: kokoroDefaultsKey),
            let decoded = try? JSONDecoder().decode(
                [String: String].self, from: data
            )
        else { return [:] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(voicevoxSpeakerIDs) else { return }
        UserDefaults.standard.set(data, forKey: PersonaVoiceStore.defaultsKey)
    }

    private func persistKokoro() {
        guard let data = try? JSONEncoder().encode(kokoroVoicePresets) else { return }
        UserDefaults.standard.set(data, forKey: PersonaVoiceStore.kokoroDefaultsKey)
    }
}
