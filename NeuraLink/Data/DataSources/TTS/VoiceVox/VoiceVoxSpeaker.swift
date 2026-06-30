//
//  VoiceVoxSpeaker.swift
//  NeuraLink
//
//  Speaker / style catalogue for VOICEVOX, plus the persona -> speaker map.
//  The map lets `VoiceVoxEngine` resolve a
//  `PersonaIdentifier` (string name) to the correct .vvm + internal style ID
//  without leaking VoiceVox details into upstream layers.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

/// Represents a VOICEVOX character (Speaker) and their available styles.
/// Some entries are "Virtual" mappings that redirect to a different internal
/// character ID inside the user's `.vvm` Model Pack — see `Mapping`.
struct VoiceVoxSpeaker: Identifiable, Codable, Sendable {
    let id: Int
    let name: String
    let styles: [VoiceVoxStyle]

    func style(named name: String) -> VoiceVoxStyle {
        styles.first { $0.name == name } ?? styles[0]
    }
}

struct VoiceVoxStyle: Identifiable, Codable, Sendable {
    let id: Int
    let name: String
}

// MARK: - Filename / internal-ID mapping

extension VoiceVoxSpeaker {

    /// Resolution of a synthesis request.
    /// Separates the physical file id (`<filenameID>.vvm`) from the internal
    /// style ID the VOICEVOX engine expects for synthesis.
    struct Mapping {
        let filenameID: Int
        let internalStyleID: Int
    }

    /// Maps any incoming ID (from UI or persona settings) to the correct
    /// physical file and internal engine ID. Needed because the bundled
    /// `.vvm` packs don't always use IDs that match their filename.
    static func map(_ incomingID: Int) -> Mapping {
        switch incomingID {
        case 2, 16:
            return Mapping(filenameID: 2, internalStyleID: 16)
        case 9:
            return Mapping(filenameID: 3, internalStyleID: 9)
        case 3, 61:
            return Mapping(filenameID: 3, internalStyleID: 61)
        case 8, 23:
            return Mapping(filenameID: 8, internalStyleID: 23)
        case 12:
            return Mapping(filenameID: 9, internalStyleID: 12)
        case 14, 67:
            return Mapping(filenameID: 14, internalStyleID: 67)
        case 20, 102:
            return Mapping(filenameID: 20, internalStyleID: 102)
        default:
            return Mapping(filenameID: incomingID, internalStyleID: incomingID)
        }
    }
}

// MARK: - Persona -> speaker map

extension VoiceVoxSpeaker {

    /// The default VoiceVox speaker used when no persona-specific choice is set.
    static let defaultSpeakerID: Int = tsumugi.id

    /// Maps a `PersonaIdentifier` (the current `state.selectedCharacterName`
    /// in `LocalLLMManager`) to a VoiceVox speaker ID. Mapping is by lowercase
    /// name so it matches how `CharacterPersona.forCharacter(named:)` resolves
    /// personas today.
    ///
    /// Precedence:
    ///   1. User override in `PersonaVoiceStore` (set via PersonaSettingsView)
    ///   2. Per-persona built-in default (Ekaterina → Himari, etc.)
    ///   3. `defaultSpeakerID` (Tsumugi)
    ///
    /// `nonisolated` so VoiceVoxEngine (which runs synthesis on its own
    /// dispatch queue) can call this synchronously without crossing the
    /// MainActor boundary. The override read uses
    /// `PersonaVoiceStore.voicevoxSpeakerIDFromDefaults` which goes directly
    /// to UserDefaults.
    nonisolated static func speakerID(for persona: String) -> Int {
        if let override = PersonaVoiceStore.voicevoxSpeakerIDFromDefaults(for: persona) {
            return override
        }
        switch persona.lowercased() {
        case "ekaterina":
            return tsumugi.id  // soft, warm, friendly — fits the Onee-san archetype
        case "sonya":
            return ritsu.id  // female, characteristic, snappy — fits the tsundere
        default:
            return defaultSpeakerID
        }
    }
}

// MARK: - Predefined Speakers

extension VoiceVoxSpeaker {

    static let allBuiltIn: [VoiceVoxSpeaker] = [
        .metan, .zundamon, .tsumugi, .ritsu, .himari, .mochiko
    ]

    static let metan = VoiceVoxSpeaker(
        id: 2,
        name: "四国めたん",
        styles: [VoiceVoxStyle(id: 16, name: "ノーマル")]
    )

    static let zundamon = VoiceVoxSpeaker(
        id: 3,
        name: "ずんだもん",
        styles: [VoiceVoxStyle(id: 61, name: "ノーマル")]
    )

    static let tsumugi = VoiceVoxSpeaker(
        id: 8,
        name: "春日部つむぎ",
        styles: [VoiceVoxStyle(id: 23, name: "ノーマル")]
    )

    static let ritsu = VoiceVoxSpeaker(
        id: 9,
        name: "波音リツ",
        styles: [VoiceVoxStyle(id: 9, name: "ノーマル")]
    )

    static let himari = VoiceVoxSpeaker(
        id: 14,
        name: "冥鳴ひまり",
        styles: [VoiceVoxStyle(id: 67, name: "ノーマル")]
    )

    static let mochiko = VoiceVoxSpeaker(
        id: 20,
        name: "もち子さん",
        styles: [VoiceVoxStyle(id: 102, name: "ノーマル")]
    )
}
