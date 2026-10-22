//
//  OpenVoiceVoicePreset.swift
//  NeuraLink
//
//  Catalogue of OpenVoice target-voice embeddings bundled with the app
//  (`se_<name>.f32`, 256 floats each, in App/Resources). The tone-color
//  converter clones the synthesized speech into the chosen voice; the picker
//  in PersonaSettings sets it per persona. Two female and two male voices.
//
//  To add one: extract its embedding offline (OpenVoice `se_extractor`),
//  bundle the `se_<name>.f32`, then add a case here.
//

import Foundation

enum OpenVoiceVoicePreset: String, CaseIterable, Identifiable {
    case riko = "se_riko"
    case akira = "se_akira"
    case touma = "se_touma"
    case ayanokoji = "se_ayanokoji"

    var id: String { rawValue }

    /// Bundled `se_<name>.f32` resource name (without extension) — what the
    /// engine loads as the target speaker embedding.
    var identifier: String { rawValue }

    var gender: CharacterGender {
        switch self {
        case .riko, .akira: return .female
        case .touma, .ayanokoji: return .male
        }
    }

    var displayName: String {
        switch self {
        case .riko: return "Riko · soft"
        case .akira: return "Akira · calm"
        case .touma: return "Kamijou · lively"
        case .ayanokoji: return "Ayanokouji · composed"
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

    /// A voice that matches the character's gender: the composed male voice
    /// for male characters (Oz, the butler, included), Riko otherwise.
    static func builtInDefault(for persona: PersonaIdentifier) -> OpenVoiceVoicePreset {
        builtInDefault(gender: VRMModelRegistry.shared.entry(named: persona)?.gender ?? .fallback)
    }

    static func builtInDefault(gender: CharacterGender) -> OpenVoiceVoicePreset {
        switch gender {
        case .male: return .ayanokoji
        case .female: return .riko
        }
    }
}
