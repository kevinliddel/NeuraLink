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
        case 16:  // Kyushu Sora is in 2.vvm
            return Mapping(filenameID: 2, internalStyleID: 16)
        case 9:  // Namine Ritsu is in 3.vvm
            return Mapping(filenameID: 3, internalStyleID: 9)
        case 61:  // Chugoku Usagi is in 3.vvm
            return Mapping(filenameID: 3, internalStyleID: 61)
        case 23:  // WhiteCUL is in 8.vvm
            return Mapping(filenameID: 8, internalStyleID: 23)
        case 12:  // Shirakami Kotaro is in 9.vvm
            return Mapping(filenameID: 9, internalStyleID: 12)
        case 67:  // Kurita Marron is in 14.vvm
            return Mapping(filenameID: 14, internalStyleID: 67)
        case 68:  // Ieru-tan is in 14.vvm
            return Mapping(filenameID: 14, internalStyleID: 68)
        case 69:  // Manbetsu Hanamaru is in 14.vvm
            return Mapping(filenameID: 14, internalStyleID: 69)
        case 74:  // Kotoyomi Nia is in 14.vvm
            return Mapping(filenameID: 14, internalStyleID: 74)
        case 102:  // Yurei-chan is in 20.vvm
            return Mapping(filenameID: 20, internalStyleID: 102)
        default:
            return Mapping(filenameID: incomingID, internalStyleID: incomingID)
        }
    }
}

// MARK: - Persona -> speaker map (added at Phase 1a, plan §5)

extension VoiceVoxSpeaker {

    /// The default VoiceVox speaker used when no persona-specific choice is set.
    static let defaultSpeakerID: Int = kotoyomiNia.id

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
            return kotoyomiNia.id  // soft, warm, friendly — fits the Onee-san archetype (Kotoyomi Nia inside 14.vvm)
        case "sonya", "dedicatus":
            return kyushuSora.id  // female, characteristic, snappy — fits the tsundere (Kyushu Sora inside 2.vvm)
        default:
            return defaultSpeakerID
        }
    }
}

// MARK: - Predefined Speakers

extension VoiceVoxSpeaker {

    static let allBuiltIn: [VoiceVoxSpeaker] = [
        .kyushuSora, .namineRitsu, .chugokuUsagi, .whiteCUL, .kotoyomiNia, .ierutan,
        .manbetsuHanamaru, .yureichan, .shirakamiKotaro, .kuritaMarron,
    ]

    static let kyushuSora = VoiceVoxSpeaker(
        id: 16,
        name: "九州そら",
        styles: [VoiceVoxStyle(id: 16, name: "ノーマル")]
    )

    static let namineRitsu = VoiceVoxSpeaker(
        id: 9,
        name: "波音リツ",
        styles: [VoiceVoxStyle(id: 9, name: "ノーマル")]
    )

    static let chugokuUsagi = VoiceVoxSpeaker(
        id: 61,
        name: "中国うさぎ",
        styles: [VoiceVoxStyle(id: 61, name: "ノーマル")]
    )

    static let whiteCUL = VoiceVoxSpeaker(
        id: 23,
        name: "WhiteCUL",
        styles: [VoiceVoxStyle(id: 23, name: "ノーマル")]
    )

    static let kotoyomiNia = VoiceVoxSpeaker(
        id: 74,
        name: "琴詠ニア",
        styles: [VoiceVoxStyle(id: 74, name: "ノーマル")]
    )

    static let ierutan = VoiceVoxSpeaker(
        id: 68,
        name: "あいえるたん",
        styles: [VoiceVoxStyle(id: 68, name: "ノーマル")]
    )

    static let manbetsuHanamaru = VoiceVoxSpeaker(
        id: 69,
        name: "満別花丸",
        styles: [VoiceVoxStyle(id: 69, name: "ノーマル")]
    )

    static let yureichan = VoiceVoxSpeaker(
        id: 102,
        name: "ユーレイちゃん",
        styles: [VoiceVoxStyle(id: 102, name: "ノーマル")]
    )

    static let shirakamiKotaro = VoiceVoxSpeaker(
        id: 12,
        name: "白上虎太郎",
        styles: [VoiceVoxStyle(id: 12, name: "ノーマル")]
    )

    static let kuritaMarron = VoiceVoxSpeaker(
        id: 67,
        name: "栗田まろん",
        styles: [VoiceVoxStyle(id: 67, name: "ノーマル")]
    )
}
