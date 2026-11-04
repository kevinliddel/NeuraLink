//
//  CompanionNotificationCopy.swift
//  NeuraLink
//
//  Text rules for companion notifications (docs/LIVING_COMPANION.md):
//  personalised facts, rejection of record-like lines, generic fallbacks.
//
//  Created by Dedicatus on 30/09/2026.
//

import Foundation

/// Text rules shared by every companion notification: facts are fed to the
/// model with the user's name in place of "the user" (facts extracted before
/// a name was set still read "User …"), and a generated line only ships
/// when it reads like a message rather than a memory-store record.
nonisolated enum CompanionNotificationCopy {
    static let lengthRange = 8...220

    /// "The user's X" → "Kevin's X", "User likes Y" → "Kevin likes Y".
    /// Unchanged when no name is set.
    static func personalize(_ text: String, userName: String) -> String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return text }
        var result = text
        for (pattern, replacement) in [(#"\b(?:the )?user's\b"#, "\(name)'s"), (#"\b(?:the )?user\b"#, name)] {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// First non-empty line of a model reply, stripped of quotes.
    static func firstLine(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))) }
            .first { !$0.isEmpty } ?? ""
    }

    /// True for a line fit to show: sane length, never "the user", and not
    /// a restatement of `source` (the fact it was written from).
    static func isConversational(_ line: String, source: String = "") -> Bool {
        guard lengthRange.contains(line.count) else { return false }
        let lowered = line.lowercased()
        if lowered.contains("the user") || lowered.hasPrefix("user ") || lowered.hasPrefix("user's") { return false }
        let normalizedSource = normalize(source)
        guard !normalizedSource.isEmpty else { return true }
        let normalizedLine = normalize(line)
        return !normalizedLine.contains(normalizedSource) && !normalizedSource.contains(normalizedLine)
    }

    /// Warm, honest fallbacks for series slots the reflection didn't word —
    /// short chats, a failed generation, or a series longer than its lines.
    static func genericLines(userName: String) -> [String] {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hey = name.isEmpty ? "Hey" : "Hey \(name)"
        let named = name.isEmpty ? "" : "\(name), "
        return [
            "\(named)I've been thinking about our last conversation…",
            "\(hey), how's your day going? I'd love to hear about it.",
            "It's quiet without you. Come say hi when you have a minute?",
            "\(named)I'm still here whenever you feel like talking.",
            "Got a moment? I'd like to pick up where we left off."
        ]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
