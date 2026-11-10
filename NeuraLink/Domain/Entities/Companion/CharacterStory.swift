//
//  CharacterStory.swift
//  NeuraLink
//
//  A character's own life, and how the right piece of it is found — Inner
//  life (docs/Companion/LIVING_COMPANION.md). The sheet holds what is
//  authored (bundled characters) or generated and edited (imported ones):
//  everyday facts, tastes, the people around them, the stage-gated
//  stories, a slow arc and how their voice changes with closeness.
//  `StoryRecall` picks what answers a topic — the model asks through the
//  `recall_own_story` tool instead of being handed a fixed slice — keeps
//  the gated stories behind the relationship stage, and reads labelled
//  lines back into a sheet. Framework-free and unit-tested.
//
//  Created by Dedicatus on 10/11/2026.
//

import Foundation

/// Everything known about a character's own life.
struct CharacterStorySheet: Equatable, Sendable {
    /// Things anyone may know: where they live, their mornings, a skill.
    var everyday: [String] = []
    /// Opinions they will argue for.
    var tastes: [String] = []
    /// The few named people who keep coming up.
    var people: [String] = []
    /// The stories the relationship stage unlocks.
    var fragments: [LoreFragment] = []
    /// One slow storyline, a beat per week of knowing each other.
    var arc: [String] = []
    /// How they speak at each relationship stage (`CompanionAffinity` label).
    var voice: [String: String] = [:]
    /// Shapes of a good answer about themselves.
    var examples: [SelfTalkExample] = []

    var isEmpty: Bool {
        everyday.isEmpty && tastes.isEmpty && people.isEmpty && fragments.isEmpty && arc.isEmpty
    }
}

/// What kind of thing a recalled line is.
enum SelfKnowledgeKind: String, Sendable {
    case everyday, taste, person, story, said, arc
}

/// One line the character knows about itself.
struct SelfKnowledge: Equatable, Sendable {
    let kind: SelfKnowledgeKind
    let text: String
    /// The lore fragment behind a `.story`, for the reveal stamp.
    var fragmentID: String?
}

nonisolated enum StoryRecall {

    /// The arc moves one beat per this long.
    static let beatEvery: TimeInterval = 7 * 86_400
    /// How many lines one recall returns.
    static let limit = 4

    // MARK: - The arc

    /// The beat the storyline has reached: the first on the day they met,
    /// one more each week, the last one held.
    static func arcBeat(_ arc: [String], firstMetAt: Date?, now: Date) -> String? {
        guard !arc.isEmpty else { return nil }
        guard let firstMetAt else { return arc[0] }
        let weeks = Int(max(0, now.timeIntervalSince(firstMetAt)) / beatEvery)
        return arc[min(weeks, arc.count - 1)]
    }

    // MARK: - Recall

    /// Everything the character may draw on at `stage`: the open material,
    /// what it has said about itself before, the arc's current beat, and
    /// only the stories the stage has unlocked.
    static func candidates(sheet: CharacterStorySheet, stage: String, said: [String], arcBeat: String?) -> [SelfKnowledge] {
        let open = Set(LoreTier.unlocked(atStage: stage))
        var out: [SelfKnowledge] = []
        if let arcBeat { out.append(SelfKnowledge(kind: .arc, text: arcBeat)) }
        out += sheet.everyday.map { SelfKnowledge(kind: .everyday, text: $0) }
        out += sheet.tastes.map { SelfKnowledge(kind: .taste, text: $0) }
        out += sheet.people.map { SelfKnowledge(kind: .person, text: $0) }
        out += said.map { SelfKnowledge(kind: .said, text: $0) }
        out += sheet.fragments.filter { open.contains($0.tier) }
            .map { SelfKnowledge(kind: .story, text: $0.text, fragmentID: $0.id) }
        return out
    }

    /// The lines that answer `topic`, best first: shared words count, and
    /// `similarity` (0…1, sentence embeddings when the device has them)
    /// adds meaning. At most one gated story comes back per call, an
    /// untold one before a told one, so a reveal stays a reveal. A topic
    /// that matches nothing ("yourself") gets a general hand: the arc,
    /// two everyday facts and one story.
    static func recall(
        topic: String, candidates: [SelfKnowledge], told: Set<String>,
        similarity: ((String, String) -> Double)? = nil
    ) -> [SelfKnowledge] {
        let wanted = keywords(topic)
        let scored: [(item: SelfKnowledge, score: Double)] = candidates.map { item in
            var score = Double(wanted.intersection(keywords(item.text)).count)
            if let similarity {
                let meaning = similarity(topic, item.text)
                if meaning > 0.35 { score += 2 * meaning }
            }
            // An untold story edges out a told one that matches as well.
            if item.kind == .story, let id = item.fragmentID, !told.contains(id), score > 0 { score += 0.25 }
            return (item, score)
        }
        let matched = scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }.map(\.item)
        return Array(oneStory(matched.isEmpty ? general(candidates, told: told) : matched).prefix(limit))
    }

    /// What the tool hands the model.
    static func resultText(_ items: [SelfKnowledge], told: Set<String>) -> String {
        guard !items.isEmpty else {
            return "Nothing of yours comes to mind on that. Say little rather than invent a history; "
                + "a small new detail is fine if it fits who you are."
        }
        let lines = items.map { item -> String in
            switch item.kind {
            case .everyday: return "- \(item.text)"
            case .taste: return "- (an opinion of yours) \(item.text)"
            case .person: return "- (someone in your life) \(item.text)"
            case .arc: return "- (what is going on in your life lately) \(item.text)"
            case .said: return "- (you told them this before; stay consistent with it) \(item.text)"
            case .story:
                let fresh = item.fragmentID.map { !told.contains($0) } ?? true
                return "- (\(fresh ? "a story you have not told them yet" : "a story you have told them before")) \(item.text)"
            }
        }
        return "From your own life. Use what fits the moment, in your own words, one thing rather than all of it:\n"
            + lines.joined(separator: "\n")
    }

    /// Content words of a text: lowercased, stop words dropped, long words
    /// cut to a stem so "books" meets "bookshelf" and "cooking" meets "cook".
    static func keywords(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return Set(words.filter { $0.count > 2 && !stopWords.contains($0) }.map { $0.count > 4 ? String($0.prefix(4)) : $0 })
    }

    private static let stopWords: Set<String> = [
        "the", "and", "you", "your", "yours", "about", "what", "when", "where", "who", "how", "why", "are", "was",
        "were", "did", "does", "have", "has", "had", "with", "that", "this", "for", "from", "any", "some", "tell",
        "like", "yourself", "something", "thing", "things", "their", "them", "they", "not", "but", "can", "ever"
    ]

    private static func general(_ candidates: [SelfKnowledge], told: Set<String>) -> [SelfKnowledge] {
        let stories = candidates.filter { $0.kind == .story }
        let story = stories.last { $0.fragmentID.map { !told.contains($0) } ?? true } ?? stories.last
        return candidates.filter { $0.kind == .arc }
            + candidates.filter { $0.kind == .everyday }.prefix(2)
            + (story.map { [$0] } ?? [])
    }

    private static func oneStory(_ items: [SelfKnowledge]) -> [SelfKnowledge] {
        var seen = false
        return items.filter { item in
            guard item.kind == .story else { return true }
            defer { seen = true }
            return !seen
        }
    }

    // MARK: - A generated sheet

    /// The labels a generated sheet is written with, and how many lines of
    /// each are asked for.
    static let sheetLabels: [(label: String, count: Int)] = [
        ("EVERYDAY", 4), ("TASTE", 3), ("PERSON", 3), ("FRIENDS", 3), ("GOODFRIENDS", 3), ("CLOSE", 3), ("ARC", 5)
    ]

    /// Reads "LABEL: text" lines into a sheet for `character` (its
    /// identity key, which the fragment ids carry). Unknown labels and
    /// lines outside 12…260 characters are dropped; extra lines beyond a
    /// label's count are ignored.
    static func parseSheet(_ raw: String, character: String) -> CharacterStorySheet {
        var lines: [String: [String]] = [:]
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].uppercased().filter(\.isLetter)
            guard let wanted = sheetLabels.first(where: { $0.label == label }) else { continue }
            let text = line[line.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”")))
            guard (12...260).contains(text.count), (lines[label]?.count ?? 0) < wanted.count else { continue }
            lines[label, default: []].append(text)
        }
        let key = character.lowercased()
        let tiers: [(LoreTier, String)] = [(.friends, "FRIENDS"), (.goodFriends, "GOODFRIENDS"), (.close, "CLOSE")]
        let fragments = tiers.flatMap { tier, label in
            (lines[label] ?? []).enumerated().map { index, text in
                LoreFragment(id: "\(key).\(tier.rawValue).\(index + 1)", tier: tier, text: text)
            }
        }
        return CharacterStorySheet(
            everyday: lines["EVERYDAY"] ?? [], tastes: lines["TASTE"] ?? [], people: lines["PERSON"] ?? [],
            fragments: fragments, arc: lines["ARC"] ?? [])
    }

    /// The instruction that makes a model write a sheet from a persona prompt.
    static func sheetInstruction(name: String) -> String {
        """
        You are writing the private life of \(name), a companion character, from the description the user gives. \
        Write in \(name)'s own first-person voice. Every line is one or two sentences, concrete and specific \
        (places, objects, small habits, named people), never a personality summary, never the words "AI", \
        "character" or "persona". Reply with EXACTLY these labelled lines and nothing else:
        EVERYDAY: (4 lines) things anyone may know — where they live or grew up, their mornings, a dislike, a skill.
        TASTE: (3 lines) an opinion they will argue for — a food, a kind of music, a habit they cannot stand.
        PERSON: (3 lines) one named person each who keeps coming up in their life, and why.
        FRIENDS: (3 lines) a quirk or a funny story they would tell a friend.
        GOODFRIENDS: (3 lines) a worry or a hope they would only tell a good friend.
        CLOSE: (3 lines) something hard or tender they would only tell someone close.
        ARC: (5 lines) one small ongoing project or storyline of theirs, in five steps from starting it to finishing it.
        Start every line with its label and a colon, one line per item, the label repeated for each item.
        """
    }
}
