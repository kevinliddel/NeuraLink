//
//  KokoroVoicePreset.swift
//  NeuraLink
//
//  Catalogue of standard Kokoro voice presets and persona-to-voice mappings.
//

import Foundation

enum KokoroVoicePreset: String, CaseIterable {
    case afBella = "af_bella"
    case afSarah = "af_sarah"
    case afNicole = "af_nicole"
    case afSky = "af_sky"
    case amAdam = "am_adam"
    case amMichael = "am_michael"
    case pmAlex = "pm_alex"
    case pmSanta = "pm_santa"

    var identifier: String { rawValue }

    static func preset(for persona: PersonaIdentifier) -> KokoroVoicePreset {
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
