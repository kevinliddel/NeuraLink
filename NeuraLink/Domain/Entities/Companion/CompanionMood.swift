//
//  CompanionMood.swift
//  NeuraLink
//
//  How a conversation left the companion — Inner life
//  (docs/Companion/LIVING_COMPANION.md). The end-of-session reflection names
//  one of these moods; until it fades it colours the first lines of the
//  next session, which idles the body favours, and the face at rest.
//
//  Framework-free and unit-tested.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation

nonisolated enum CompanionMood: String, CaseIterable, Sendable {
    case bright, playful, calm, tender, wistful, weary

    /// A mood older than this is forgotten: a new day starts neutral.
    static let lifetime: TimeInterval = 24 * 3600
    /// The resting face fades out over this long after the character loads.
    static let faceFade: TimeInterval = 10 * 60

    /// The vocabulary the reflection prompt offers.
    static let promptVocabulary = "bright, playful, calm, tender, wistful or weary"

    /// The reflection's MOOD line, however it was cased or punctuated;
    /// near-synonyms map onto the six.
    static func parse(_ text: String) -> CompanionMood? {
        let word = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .first { !$0.isEmpty } ?? ""
        return CompanionMood(rawValue: word) ?? aliases[word]
    }

    private static let aliases: [String: CompanionMood] = [
        "happy": .bright, "cheerful": .bright, "excited": .bright, "glad": .bright,
        "amused": .playful, "mischievous": .playful, "teasing": .playful,
        "content": .calm, "peaceful": .calm, "relaxed": .calm, "serene": .calm,
        "warm": .tender, "affectionate": .tender, "fond": .tender, "moved": .tender,
        "sad": .wistful, "melancholy": .wistful, "thoughtful": .wistful, "pensive": .wistful,
        "tired": .weary, "drained": .weary, "exhausted": .weary, "heavy": .weary
    ]

    // MARK: - Voice

    /// The Companion State line.
    var promptLine: String {
        "Your mood coming into this session: \(rawValue) — \(colour). "
            + "Let it colour your first lines, then follow the conversation."
    }

    private var colour: String {
        switch self {
        case .bright: return "lighter and quicker than usual"
        case .playful: return "in a teasing, easy humour"
        case .calm: return "settled and unhurried"
        case .tender: return "soft, a little more affectionate than usual"
        case .wistful: return "quieter, thoughtful, a touch wistful"
        case .weary: return "a little tired, slower to warm up"
        }
    }

    // MARK: - Body

    /// Idles that read as resting rather than fidgeting, and the ones that
    /// read as energy; the rest of each pool is neutral.
    static let quietIdles: Set<String> = ["relax", "waiting"]
    static let livelyIdles: Set<String> = ["male_powerful", "male_stretching_arms"]

    /// How gladly the body picks an idle clip while in this mood; 1 is as
    /// usual.
    func idleWeight(forClip name: String) -> Double {
        let quiet = Self.quietIdles.contains(name)
        let lively = Self.livelyIdles.contains(name)
        switch self {
        case .bright, .playful: return quiet ? 0.5 : (lively ? 1.5 : 1)
        case .calm: return quiet ? 1.5 : (lively ? 0.75 : 1)
        case .tender: return 1
        case .wistful, .weary: return quiet ? 2 : (lively ? 0.5 : 1)
        }
    }

    /// Low expression weights the face rests in while no emotion plays.
    struct RestingFace: Equatable, Sendable {
        var happy: Float = 0
        var relaxed: Float = 0
        var sad: Float = 0
    }

    var restingFace: RestingFace {
        switch self {
        case .bright: return RestingFace(happy: 0.18)
        case .playful: return RestingFace(happy: 0.15, relaxed: 0.05)
        case .calm: return RestingFace(relaxed: 0.2)
        case .tender: return RestingFace(happy: 0.08, relaxed: 0.15)
        case .wistful: return RestingFace(relaxed: 0.1, sad: 0.12)
        case .weary: return RestingFace(relaxed: 0.2, sad: 0.08)
        }
    }

    /// How much of the resting face is left `elapsed` seconds after the
    /// character loaded: full at first, gone after `faceFade`.
    static func faceStrength(elapsed: TimeInterval) -> Float {
        Float(max(0, 1 - elapsed / faceFade))
    }

    /// Whether a mood recorded at `recordedAt` still applies.
    static func applies(recordedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(recordedAt) < lifetime
    }

    /// One of `items` drawn with the given weights, `roll` in 0..<1 choosing
    /// where in the cumulative range it lands; nil when nothing has weight.
    static func pick<T>(_ items: [T], weight: (T) -> Double, roll: Double) -> T? {
        let weights = items.map { max(0, weight($0)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var remaining = min(max(roll, 0), 0.999_999) * total
        for (item, w) in zip(items, weights) {
            remaining -= w
            if remaining < 0 { return item }
        }
        return items.last
    }
}
