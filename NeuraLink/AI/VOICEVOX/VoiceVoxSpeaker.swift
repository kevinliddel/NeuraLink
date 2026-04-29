//
//  VoiceVoxSpeaker.swift
//  NeuraLink
//
//  Data model for VOICEVOX characters and their styles.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

struct VoiceVoxSpeaker: Identifiable, Codable, Sendable {
    let id: Int
    let name: String
    let styles: [VoiceVoxStyle]
    
    /// Returns the style with the given name, or the first one if not found.
    func style(named name: String) -> VoiceVoxStyle {
        styles.first { $0.name == name } ?? styles[0]
    }
}

struct VoiceVoxStyle: Identifiable, Codable, Sendable {
    let id: Int
    let name: String
}

extension VoiceVoxSpeaker {
    /// Result containing both the file to load and the internal style ID to use.
    struct Mapping {
        let filenameID: Int
        let internalStyleID: Int
    }
    
    /// Maps any incoming ID (legacy or style) to the correct file and internal style.
    static func map(_ incomingID: Int) -> Mapping {
        switch incomingID {
        case 2, 16: // Metan/Sora
            return Mapping(filenameID: 2, internalStyleID: 16)
        case 3, 61: // Zundamon/Usagi
            return Mapping(filenameID: 3, internalStyleID: 61)
        case 8, 23: // Tsumugi/WhiteCUL
            return Mapping(filenameID: 8, internalStyleID: 23)
        case 9:     // Ritsu
            return Mapping(filenameID: 9, internalStyleID: 9)
        case 14, 67: // Himari/Marron
            return Mapping(filenameID: 14, internalStyleID: 67)
        case 20, 102: // Mochiko/Yurei
            return Mapping(filenameID: 20, internalStyleID: 102)
        default:
            return Mapping(filenameID: incomingID, internalStyleID: incomingID)
        }
    }
}

extension VoiceVoxSpeaker {
    /// Predefined speakers re-mapped to match the user's actual VVM file contents.
    static let metan = VoiceVoxSpeaker(
        id: 2, // Filename: 2.vvm
        name: "四国めたん",
        styles: [VoiceVoxStyle(id: 16, name: "ノーマル")] // Uses Sora's ID from 2.vvm
    )

    static let zundamon = VoiceVoxSpeaker(
        id: 3, // Filename: 3.vvm
        name: "ずんだもん",
        styles: [VoiceVoxStyle(id: 61, name: "ノーマル")] // Uses Usagi's ID from 3.vvm
    )

    static let tsumugi = VoiceVoxSpeaker(
        id: 8, // Filename: 8.vvm
        name: "春日部つむぎ",
        styles: [VoiceVoxStyle(id: 23, name: "ノーマル")] // Uses WhiteCUL's ID from 8.vvm
    )

    static let ritsu = VoiceVoxSpeaker(
        id: 9, // Filename: 9.vvm
        name: "波音リツ",
        styles: [VoiceVoxStyle(id: 9, name: "ノーマル")]
    )

    static let himari = VoiceVoxSpeaker(
        id: 14, // Filename: 14.vvm
        name: "冥鳴ひまり",
        styles: [VoiceVoxStyle(id: 14, name: "ノーマル")]
    )

    static let mochiko = VoiceVoxSpeaker(
        id: 20, // Filename: 20.vvm
        name: "もち子さん",
        styles: [VoiceVoxStyle(id: 20, name: "ノーマル")]
    )

    static let allBuiltIn: [VoiceVoxSpeaker] = [
        .metan, .zundamon, .tsumugi, .ritsu, .himari, .mochiko
    ]
}
