//
//  OpenVoiceVoicePreset.swift
//  NeuraLink
//
//  Catalogue of OpenVoice target-voice embeddings bundled with the app
//  (`se_<name>.f32`). The tone-color converter clones the synthesized speech
//  into the chosen voice; the picker in PersonaSettings sets it per persona.
//
//  NOTE: the current entries are PLACEHOLDER voices carried over from the
//  source pack (SynapLink). Replace with NeuraLink persona voices extracted
//  offline (OpenVoice `se_extractor`) and bundle/host the matching
//  `se_<name>.f32`, then add cases here.
//

import Foundation

enum OpenVoiceVoicePreset: String, CaseIterable, Identifiable {
    case riko = "se_riko"
    case akira = "se_akira"

    var id: String { rawValue }

    /// Bundled `se_<name>.f32` resource name (without extension) — what the
    /// engine loads as the target speaker embedding.
    var identifier: String { rawValue }

    var displayName: String {
        switch self {
        case .riko:  return "Riko (placeholder · soft)"
        case .akira: return "Akira (placeholder · calm)"
        }
    }

    /// Persona-keyed voice. Consults `PersonaVoiceStore` for a user override
    /// first, then the built-in default.
    static func preset(for persona: PersonaIdentifier) -> OpenVoiceVoicePreset {
        if let overrideID = PersonaVoiceStore.openVoiceVoiceIDFromDefaults(for: persona),
           let override = OpenVoiceVoicePreset(rawValue: overrideID) {
            return override
        }
        return builtInDefault(for: persona)
    }

    static func builtInDefault(for persona: PersonaIdentifier) -> OpenVoiceVoicePreset {
        _ = persona
        return .riko
    }
}
