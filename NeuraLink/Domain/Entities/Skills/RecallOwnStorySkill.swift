//
//  RecallOwnStorySkill.swift
//  NeuraLink
//
//  `recall_own_story` tool — lets the model reach for its own life when
//  the conversation calls for it (docs/Companion/LIVING_COMPANION.md,
//  Inner life), the way `search_memory` reaches for the user's. Returns
//  the lines of the character's story that fit the topic: everyday facts,
//  tastes, people, the arc, what it said before, and one story the
//  relationship stage has unlocked.
//

import Foundation

@MainActor
final class RecallOwnStorySkill: Skill {
    static let toolName = AppFunctionTool.recallOwnStory
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        // Inner life off: nothing of its own is shared, and nothing is stamped.
        guard PresenceSettings.shared.innerLifeEnabled else { return "You keep that to yourself for now." }
        let topic = (arguments["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let character = RealtimeChatState.shared.selectedCharacterName
        let result = CharacterStoryProvider.shared.recall(topic: topic, character: character)
        nlLogSensitive("֎ [FunctionCall] recall_own_story \"\(topic)\" → \(result.count) chars", level: .info)
        return result
    }
}
