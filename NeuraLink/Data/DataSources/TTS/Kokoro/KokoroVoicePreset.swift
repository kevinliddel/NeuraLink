//
//  KokoroVoicePreset.swift
//  NeuraLink
//
//  Catalogue of Kokoro voice presets actually present in the bundled
//  `voices.bin`. The shipped file contains 103 voice styles:
//    - 2 American Female (af_*)
//    - 1 British Female (bf_*)
//    - ~100 Chinese voices (zf_*, zm_*)
//
//  Previous revisions had `af_bella`/`af_sarah`/`am_adam`-style names that
//  belong to the upstream Kokoro release but are NOT in this app's voices
//  pack — every preset request was hitting the C++ "voice not found, using
//  default" fallback. Persona pickers were effectively broken. This enum
//  now mirrors the file exactly so saved selections actually take effect.
//

import Foundation

enum KokoroVoicePreset: String, CaseIterable, Identifiable {
    // MARK: - English voices

    case afMaple = "af_maple"     // American Female · warm, conversational
    case afSol = "af_sol"         // American Female · bright
    case bfVale = "bf_vale"       // British Female · neutral

    // MARK: - Chinese voices (subset — full set is in `allInVoiceFile`)

    case zf001 = "zf_001"         // Chinese Female · first stock voice
    case zf005 = "zf_005"
    case zf017 = "zf_017"
    case zm009 = "zm_009"         // Chinese Male · first stock voice
    case zm025 = "zm_025"

    var id: String { rawValue }
    var identifier: String { rawValue }

    /// Human-readable label for picker UI.
    var displayName: String {
        switch self {
        case .afMaple: return "Maple (American Female · Warm)"
        case .afSol:   return "Sol (American Female · Bright)"
        case .bfVale:  return "Vale (British Female · Neutral)"
        case .zf001:   return "Chinese Female #001"
        case .zf005:   return "Chinese Female #005"
        case .zf017:   return "Chinese Female #017"
        case .zm009:   return "Chinese Male #009"
        case .zm025:   return "Chinese Male #025"
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
    /// Only English voices are picked here — the Chinese voices are
    /// available as user overrides but aren't the right pick for the
    /// English-speaking on-device LLM personas.
    static func builtInDefault(for persona: PersonaIdentifier) -> KokoroVoicePreset {
        switch persona.lowercased() {
        case "ekaterina":
            return .afMaple
        case "sonya":
            return .bfVale
        default:
            return .afMaple
        }
    }
}
