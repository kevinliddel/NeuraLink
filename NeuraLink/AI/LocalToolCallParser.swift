//
//  LocalToolCallParser.swift
//  NeuraLink
//
//  Minimal local tool-calling format for offline/local SLM mode.
//
//  Expected format (model output):
//    <tool name="create_reminder">{ "title": "...", "notes": "..." }</tool>
//

import Foundation

struct LocalToolCall {
    let name: String
    let arguments: [String: Any]
}

enum LocalToolCallParser {
    static func firstToolCall(in text: String) -> LocalToolCall? {
        let pattern = #"<tool\s+name\s*=\s*\"([^\"]+)\"\s*>([\s\S]*?)<\/tool>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges >= 3
        else { return nil }

        let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return LocalToolCall(name: name, arguments: obj)
    }

    static func strippedText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<tool[^>]*>[\s\S]*?<\/tool>"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
