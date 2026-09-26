//
//  ToolGrammarBuilder.swift
//  NeuraLink
//
//  Turns the curated local tool set into (a) a GBNF grammar that constrains
//  sampling once the model starts a `<tool` tag and (b) the one-line-per-tool
//  prompt block, so prompt and grammar can never disagree
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §A1). Supported property types:
//  string, string+enum, number, integer, boolean. Required keys in schema
//  order; optional keys allowed after them.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

enum ToolGrammarBuilder {

    /// Tools the local model may call. Prompt tokens are the scarce
    /// resource on a 1B, so this stays short.
    static let localToolNames: [String] = [
        AppFunctionTool.rememberFact, AppFunctionTool.searchMemory, AppFunctionTool.getWeather,
        AppFunctionTool.createReminder, AppFunctionTool.playMusic
    ]

    /// Lazy-grammar trigger: the grammar engages at the first `<tool`.
    static let triggerPattern = "[\\s\\S]*?(<tool)"
    static let rootRule = "root"

    struct Property {
        let name: String
        let type: String
        let enumValues: [String]
        let required: Bool
    }

    struct Tool {
        let name: String
        let properties: [Property]
    }

    // MARK: - Schema → model

    /// Parses the OpenAI-style function schemas for `names`. Tools with an
    /// unsupported property type are skipped (and logged by the caller).
    static func tools(named names: [String], from schemas: [[String: Any]]) -> [Tool] {
        names.compactMap { name in
            guard let schema = schemas.first(where: { $0["name"] as? String == name }),
                  let parameters = schema["parameters"] as? [String: Any],
                  let properties = parameters["properties"] as? [String: Any]
            else { return nil }
            let required = parameters["required"] as? [String] ?? []
            let ordered = required + properties.keys.sorted().filter { !required.contains($0) }
            var parsed: [Property] = []
            for key in ordered {
                guard let spec = properties[key] as? [String: Any], let type = spec["type"] as? String else { return nil }
                guard ["string", "number", "integer", "boolean"].contains(type) else { return nil }
                parsed.append(Property(
                    name: key, type: type, enumValues: spec["enum"] as? [String] ?? [], required: required.contains(key)))
            }
            return Tool(name: name, properties: parsed)
        }
    }

    // MARK: - GBNF

    static func gbnf(for tools: [Tool]) -> String? {
        guard !tools.isEmpty else { return nil }
        var rules: [String] = []
        rules.append("\(rootRule) ::= \"<tool name=\\\"\" call \"</tool>\"")
        rules.append("call ::= " + tools.map { "call-\(ident($0.name))" }.joined(separator: " | "))
        for tool in tools {
            let id = ident(tool.name)
            rules.append("call-\(id) ::= \"\(tool.name)\\\">\" obj-\(id)")
            rules.append("obj-\(id) ::= " + objectRule(for: tool, id: id))
            for property in tool.properties where !property.enumValues.isEmpty {
                let literals = property.enumValues.map { "\"\\\"\($0)\\\"\"" }.joined(separator: " | ")
                rules.append("enum-\(id)-\(ident(property.name)) ::= \(literals)")
            }
        }
        rules.append(contentsOf: [
            "string ::= \"\\\"\" chars \"\\\"\"",
            "chars ::= ( [^\"\\\\\\x7F\\x00-\\x1F] | \"\\\\\" ( [\"\\\\/bfnrt] | \"u\" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] ) )*",
            "number ::= \"-\"? ( \"0\" | [1-9] [0-9]* ) ( \".\" [0-9]+ )?",
            "integer ::= \"-\"? ( \"0\" | [1-9] [0-9]* )",
            "boolean ::= \"true\" | \"false\"",
            "ws ::= [ \\t\\n]*"
        ])
        return rules.joined(separator: "\n") + "\n"
    }

    private static func objectRule(for tool: Tool, id: String) -> String {
        let required = tool.properties.filter(\.required)
        let optional = tool.properties.filter { !$0.required }
        var parts: [String] = ["\"{\" ws"]
        for (index, property) in required.enumerated() {
            if index > 0 { parts.append("\",\" ws") }
            parts.append(pair(property, id: id))
        }
        for property in optional {
            let separator = required.isEmpty ? "" : "\",\" ws "
            parts.append("( \(separator)\(pair(property, id: id)) )?")
        }
        parts.append("ws \"}\"")
        return parts.joined(separator: " ")
    }

    private static func pair(_ property: Property, id: String) -> String {
        let value: String
        if !property.enumValues.isEmpty {
            value = "enum-\(id)-\(ident(property.name))"
        } else {
            value = property.type
        }
        return "\"\\\"\(property.name)\\\"\" ws \":\" ws \(value) ws"
    }

    private static func ident(_ raw: String) -> String {
        raw.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    // MARK: - Prompt block

    /// Compact instruction listing each tool with a filled-in shape, so the
    /// grammar's expectation and the model's example match token for token.
    static func promptBlock(for tools: [Tool]) -> String {
        guard !tools.isEmpty else { return "" }
        let examples = tools.map { tool -> String in
            let pairs = tool.properties.filter(\.required).map { property -> String in
                let placeholder = property.enumValues.first.map { "\"\($0)\"" }
                    ?? (property.type == "string" ? "\"…\"" : (property.type == "boolean" ? "true" : "0"))
                return "\"\(property.name)\":\(placeholder)"
            }.joined(separator: ",")
            return "<tool name=\"\(tool.name)\">{\(pairs)}</tool>"
        }
        return "Tools — when the user asks for one, output ONLY the tag, nothing else: "
            + examples.joined(separator: " ") + "\n"
    }
}
