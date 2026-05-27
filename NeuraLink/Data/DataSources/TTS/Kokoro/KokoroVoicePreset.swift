//
//  KokoroVoicePreset.swift
//  NeuraLink
//
//  Catalogue of standard Kokoro voice presets and persona-to-voice mappings.
//

import Foundation

enum KokoroVoicePreset: String, CaseIterable, Identifiable {
    case afBella = "af_bella"
    case afSarah = "af_sarah"
    case afNicole = "af_nicole"
    case afSky = "af_sky"
    case amAdam = "am_adam"
    case amMichael = "am_michael"
    case pmAlex = "pm_alex"
    case pmSanta = "pm_santa"

    var id: String { rawValue }
    var identifier: String { rawValue }

    /// Human-readable label for picker UI.
    var displayName: String {
        switch self {
        case .afBella: return "Bella (Female · Warm)"
        case .afSarah: return "Sarah (Female · Calm)"
        case .afNicole: return "Nicole (Female · Bright)"
        case .afSky: return "Sky (Female · Neutral)"
        case .amAdam: return "Adam (Male · Standard)"
        case .amMichael: return "Michael (Male · Deep)"
        case .pmAlex: return "Alex (Male · Casual)"
        case .pmSanta: return "Santa (Male · Jolly)"
        }
    }

    /// Persona-keyed default. Consults `PersonaVoiceStore` for a user override
    /// first, then falls back to the built-in mapping.
    static func preset(for persona: PersonaIdentifier) -> KokoroVoicePreset {
        if let overrideID = PersonaVoiceStore.kokoroVoiceIDFromDefaults(for: persona),
           let override = KokoroVoicePreset(rawValue: overrideID) {
            return override
        }
        return builtInDefault(for: persona)
    }

    /// Built-in default for a persona, independent of any user override. Used
    /// when the picker needs a placeholder before the user makes a choice.
    static func builtInDefault(for persona: PersonaIdentifier) -> KokoroVoicePreset {
        switch persona.lowercased() {
        case "ekaterina":
            return .afSarah
        case "sonya":
            return .afBella
        default:
            return .afSky
        }
    }
}
