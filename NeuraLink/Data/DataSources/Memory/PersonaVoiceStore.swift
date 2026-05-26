//
//  PersonaVoiceStore.swift
//  NeuraLink
//
//  Per-persona voice preference. Engine selection itself is automatic
//  (§3.1) — the user only picks WHICH VOICEVOX speaker to use for the
//  persona. Other engines (System, F5-TTS) infer their voice from the
//  persona name + device locale and don't need overrides.
//
//  Persists in UserDefaults as a JSON-encoded `[PersonaIdentifier: Int]`
//  (filename ID matching `VoiceVoxSpeaker.allBuiltIn`).
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

    nonisolated static let defaultsKey = "com.neuralink.tts.persona_voicevox_speaker_ids"

    private init() {
        voicevoxSpeakerIDs = PersonaVoiceStore.loadFromDefaults()
    }

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

    private nonisolated static func loadFromDefaults() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(
                [String: Int].self, from: data
            )
        else { return [:] }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(voicevoxSpeakerIDs) else { return }
        UserDefaults.standard.set(data, forKey: PersonaVoiceStore.defaultsKey)
    }
}
