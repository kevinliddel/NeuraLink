//
//  CharacterGender.swift
//  NeuraLink
//
//  How a character presents, chosen per model: fixed for the bundled ones,
//  picked by the user when a VRM is imported (and editable afterwards).
//  Nothing about the file says it — VRM metadata carries no gender — so it
//  is an app-side label. It decides which idle, resting and pose clips the
//  body draws on (AnimationCatalogue); talking, the entrance and every
//  episode clip are shared.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

nonisolated enum CharacterGender: String, Codable, CaseIterable, Sendable {
    case female
    case male

    /// Rows and models that predate the label.
    static let fallback: CharacterGender = .female

    var title: String {
        switch self {
        case .female: return "Female"
        case .male: return "Male"
        }
    }

    /// Custom symbol in the asset catalogue (venus.symbolset, mars.symbolset):
    /// the pickers show the sign alone and `title` is what VoiceOver reads.
    var symbolAsset: String {
        switch self {
        case .female: return "venus"
        case .male: return "mars"
        }
    }

    /// Tolerant of unknown or missing stored values.
    init(stored: String?) {
        self = stored.flatMap(CharacterGender.init(rawValue:)) ?? .fallback
    }
}
