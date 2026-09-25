//
//  MemoryFactExtraction.swift
//  NeuraLink
//
//  Prompts and parsers for the retain step (docs/AGENTIC_MEMORY.md
//  §Retain). Cloud models get Hindsight's structured five-field extraction
//  (what / when / who / type / caused_by) as JSON; 1–2B local models get the
//  proven line-per-fact prompt from LocalLLMFactExtractor with its strict
//  quality gates, because small models cannot be trusted with JSON.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

enum MemoryFactExtraction {

    /// A dialogue line handed to extraction.
    struct Turn {
        let role: String   // "user" | "assistant"
        let text: String
        let timestamp: Date
    }

    static let cloudMaxTokens = 600
    static let localMaxTokens = 80

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd (EEEE)"
        return f
    }()

    // MARK: - Cloud (JSON)

    static func cloudSystemPrompt(assistantName: String) -> String {
        """
        Extract SIGNIFICANT facts from a conversation between the user and \(assistantName) (the assistant). \
        Be SELECTIVE — only facts worth remembering long-term: personal info, preferences, relationships, \
        significant events, plans, expertise, emotional context, corrections. Skip greetings, filler, \
        process chatter and repeats. Consolidate related statements into ONE fact.
        Return ONLY a JSON array. Each item:
          {"what": "1-2 sentences, third person, self-contained",
           "when": "YYYY-MM-DD, YYYY-MM-DD/YYYY-MM-DD, YYYY-MM, YYYY, or null when timeless",
           "who": ["user", "Emily (user's roommate)"],
           "type": "world" or "experience",
           "caused_by": null or the zero-based index of an earlier item in this array}
        Rules: convert ALL relative dates ("yesterday", "last week") to absolute dates using the message dates. \
        Always include "user" in who when the fact is about the user. Resolve references \
        ("my roommate" + "Emily" → "Emily (user's roommate)"). type is "experience" ONLY for things \
        \(assistantName) itself did; the user's own statements are "world". Return [] when nothing is worth keeping.
        """
    }

    static func cloudUserPrompt(turns: [Turn], assistantName: String) -> String {
        turns.map { turn in
            let speaker = turn.role == "user" ? "User" : assistantName
            return "[\(dateFormatter.string(from: turn.timestamp))] \(speaker): \(turn.text)"
        }.joined(separator: "\n")
    }

    /// Parses the JSON array (tolerating code fences and a `{"facts": []}`
    /// wrapper). `reference` resolves relative `when` strings.
    static func parseCloud(_ raw: String, reference: Date) -> [ExtractedFact] {
        guard let data = jsonPayload(in: raw) else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let dict = object as? [String: Any], let array = dict["facts"] as? [[String: Any]] {
            items = array
        } else {
            return []
        }

        var facts: [ExtractedFact] = []
        for item in items {
            guard let what = (item["what"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isAcceptable(what) else { continue }
            var fact = ExtractedFact(text: what)
            if let type = item["type"] as? String, type.lowercased() == "experience" {
                fact.factType = .experience
            }
            if let when = item["when"] as? String,
               let span = MemoryTemporalParser.span(from: when, reference: reference) {
                fact.occurredStart = span.0
                fact.occurredEnd = span.1
            }
            var who = (item["who"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            who.append(contentsOf: MemoryEntityExtractor.entities(in: what, includeUser: false))
            if MemoryEntityExtractor.isAboutUser(what) { who.append(MemoryEntityExtractor.userEntity) }
            fact.entities = dedupe(who)
            if let cause = item["caused_by"] as? Int, cause >= 0, cause < facts.count {
                fact.causedByIndex = cause
            }
            facts.append(fact)
        }
        return facts
    }

    private static func jsonPayload(in raw: String) -> Data? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = text.range(of: "```json") ?? text.range(of: "```") {
            text = String(text[fence.upperBound...])
            if let close = text.range(of: "```") { text = String(text[..<close.lowerBound]) }
        }
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }),
              let end = text.lastIndex(where: { $0 == "]" || $0 == "}" }), start < end
        else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    // MARK: - Local (labeled lines)

    /// Reuses LocalLLMFactExtractor's compact prompt — tuned for 1B models.
    static func localPrompt(turns: [Turn]) -> String {
        let events = turns.map {
            ChatEventItem(id: 0, role: $0.role == "user" ? "user" : "ai", kind: "message",
                          title: "", detail: $0.text, pinned: false, timestamp: $0.timestamp)
        }
        return LocalLLMFactExtractor.shared.buildPrompt(from: events)
    }

    /// Runs the local output through LocalLLMFactExtractor's quality gates;
    /// every surviving line is a timeless world fact about the user.
    static func parseLocal(_ raw: String) -> [ExtractedFact] {
        LocalLLMFactExtractor.shared.parseFacts(raw).map { line in
            var fact = ExtractedFact(text: line)
            fact.entities = MemoryEntityExtractor.entities(in: line, includeUser: true)
            return fact
        }
    }

    // MARK: - Shared gates

    static func isAcceptable(_ text: String) -> Bool {
        (12...300).contains(text.count) && text.rangeOfCharacter(from: .letters) != nil
    }

    static func dedupe(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            let key = name.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}
