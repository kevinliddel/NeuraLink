//
//  VoiceVoxSpeaker.swift
//  NeuraLink
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

/// Represents a VOICEVOX character (Speaker) and their associated styles.
///
/// In the NeuraLink implementation, some speakers are "Virtual" mappings that redirect to
/// different internal characters found within the user's .vvm Model Packs.
struct VoiceVoxSpeaker: Identifiable, Codable, Sendable {
    /// The unique identifier for this speaker (usually matches the .vvm filename).
    let id: Int
    /// The display name of the character in the UI.
    let name: String
    /// The collection of vocal styles available for this character.
    let styles: [VoiceVoxStyle]
    
    /// Returns the style with the given name, or the first one if not found.
    /// - Parameter name: The name of the style (e.g., "Normal", "Sweet").
    /// - Returns: A matching style object or the default style.
    func style(named name: String) -> VoiceVoxStyle {
        styles.first { $0.name == name } ?? styles[0]
    }
}

/// Represents a specific vocal style (e.g., Normal, Whisper) for a VOICEVOX speaker.
struct VoiceVoxStyle: Identifiable, Codable, Sendable {
    /// The internal ID used by the VOICEVOX C-API for synthesis.
    let id: Int
    /// The display name of the style.
    let name: String
}

// MARK: - Mapping Logic

extension VoiceVoxSpeaker {
    /// A container for the resolution of a synthesis request.
    /// It separates the physical file storage from the internal engine IDs.
    struct Mapping {
        /// The ID of the .vvm file that must be loaded (e.g., 2 for "2.vvm").
        let filenameID: Int
        /// The actual style ID that the VOICEVOX engine expects for synthesis.
        let internalStyleID: Int
    }
    
    /// Maps any incoming ID (from legacy settings or UI) to the correct physical file and internal engine ID.
    ///
    /// This redirection is necessary because the user's .vvm files are "Model Packs" where the
    /// internal IDs do not always match the filenames.
    ///
    /// - Parameter incomingID: The ID requested by the UI or saved in the persona.
    /// - Returns: A `Mapping` object containing the correct file and internal ID.
    static func map(_ incomingID: Int) -> Mapping {
        switch incomingID {
        case 2, 16:
            // Metan (ID 2) file contains Kyushu Sora (ID 16)
            return Mapping(filenameID: 2, internalStyleID: 16)
            
        case 3, 61:
            // Zundamon (ID 3) file contains Chugoku Usagi (ID 61)
            return Mapping(filenameID: 3, internalStyleID: 61)
            
        case 8, 23:
            // Tsumugi (ID 8) file contains WhiteCUL (ID 23)
            return Mapping(filenameID: 8, internalStyleID: 23)
            
        case 9:
            // Ritsu (ID 9) file contains Ritsu (ID 9)
            return Mapping(filenameID: 9, internalStyleID: 9)
            
        case 14, 67:
            // Himari (ID 14) file contains Kurita Marron (ID 67)
            return Mapping(filenameID: 14, internalStyleID: 67)
            
        case 20, 102:
            // Mochiko (ID 20) file contains Yurei-chan (ID 102)
            return Mapping(filenameID: 20, internalStyleID: 102)
            
        default:
            // Fallback: assume the ID matches both the file and the internal style
            return Mapping(filenameID: incomingID, internalStyleID: incomingID)
        }
    }
}

// MARK: - Predefined Speakers

extension VoiceVoxSpeaker {
    /// The primary speaker list used to populate the UI.
    /// Note: These are mapped to the user's actual available .vvm packs.
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
