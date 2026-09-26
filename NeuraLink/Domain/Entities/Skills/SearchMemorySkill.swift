//
//  SearchMemorySkill.swift
//  NeuraLink
//
//  `search_memory` tool — lets the model query long-term memory
//  agentically mid-conversation (docs/AGENTIC_MEMORY.md §Reflect). Runs the
//  zero-LLM retrieval ladder and hands the evidence back as text for the
//  model to reason over.
//

import Foundation

@MainActor
final class SearchMemorySkill: Skill {
    static let toolName = AppFunctionTool.searchMemory
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        guard let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else { return "I need a query to search my memory." }
        guard MemorySettings.shared.isEnabled else { return "Long-term memory is turned off." }

        let character = RealtimeChatState.shared.selectedCharacterName
        let evidence = MemoryReflect.shared.evidence(for: query, character: character)
        nlLogSensitive("֎ [FunctionCall] search_memory \"\(query)\" → \(evidence.count) chars", level: .info)
        guard !evidence.isEmpty else { return "Nothing relevant in memory." }
        return "Memory search results (newest first where dated):\n\(evidence)"
    }
}
