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

    var symbol: String {
        switch self {
        case .female: return "figure.stand.dress"
        case .male: return "figure.stand"
        }
    }

    /// Tolerant of unknown or missing stored values.
    init(stored: String?) {
        self = stored.flatMap(CharacterGender.init(rawValue:)) ?? .fallback
    }
}
