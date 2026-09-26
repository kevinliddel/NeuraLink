//
//  MemoryDisposition.swift
//  NeuraLink
//
//  Per-character disposition traits (skepticism, literalism, empathy on a
//  1–5 scale) applied to the LLM-backed memory steps — consolidation,
//  mental-model refresh and reflect — never to recall
//  (docs/AGENTIC_MEMORY.md §Disposition). Numbers are verbalised because a
//  small model reads "skepticism=5" as metadata rather than an instruction.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

struct MemoryDisposition: Equatable, Sendable {
    var skepticism: Int = 3
    var literalism: Int = 3
    var empathy: Int = 3

    static let neutral = MemoryDisposition()

    private static let key = "com.neuralink.memory.disposition."

    /// Persisted per character; neutral when never set.
    static func forCharacter(_ character: String) -> MemoryDisposition {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: key + character.lowercased()) else { return .neutral }
        return MemoryDisposition(
            skepticism: clamp(dict["skepticism"] as? Int ?? 3),
            literalism: clamp(dict["literalism"] as? Int ?? 3),
            empathy: clamp(dict["empathy"] as? Int ?? 3))
    }

    func save(forCharacter character: String) {
        UserDefaults.standard.set(
            ["skepticism": skepticism, "literalism": literalism, "empathy": empathy],
            forKey: Self.key + character.lowercased())
    }

    private static func clamp(_ value: Int) -> Int { min(5, max(1, value)) }

    /// Natural-language rendering for prompts. Neutral traits are omitted so
    /// an all-3 disposition contributes nothing.
    var promptDescription: String {
        var lines: [String] = []
        switch skepticism {
        case 1: lines.append("You accept information at face value and rarely question it.")
        case 2: lines.append("You are fairly trusting of what you are told.")
        case 4: lines.append("You are skeptical and look for inconsistencies before accepting a claim.")
        case 5: lines.append("You are highly skeptical and critically examine all information for accuracy and hidden motives.")
        default: break
        }
        switch literalism {
        case 1: lines.append("You interpret information very flexibly, reading between the lines and inferring intent.")
        case 2: lines.append("You allow some interpretation beyond the literal words.")
        case 4: lines.append("You stick closely to what was literally said.")
        case 5: lines.append("You interpret everything strictly literally and never infer unstated intent.")
        default: break
        }
        switch empathy {
        case 1: lines.append("You focus on facts and disregard emotional context.")
        case 2: lines.append("You give emotional context little weight.")
        case 4: lines.append("You consider the emotional state and circumstances of others when forming memories.")
        case 5: lines.append("You strongly consider the emotional state and circumstances of others when forming memories.")
        default: break
        }
        return lines.joined(separator: " ")
    }
}
