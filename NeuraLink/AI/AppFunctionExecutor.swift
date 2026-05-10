//
//  AppFunctionExecutor.swift
//  NeuraLink
//
//  Executes iOS function calls requested by the AI.
//  Uses a modular Skill system where each tool is a standalone class.
//
//  Created by Dedicatus on 27/04/2026.
//

import Foundation

@MainActor
final class AppFunctionExecutor {

    static let shared = AppFunctionExecutor()

    /// Registry of all available skills, keyed by their tool name.
    private let skills: [String: any Skill]

    /// UI action stored here instead of firing immediately.
    /// Executed by OpenAIRealtimeManager after the AI finishes speaking the result.
    var pendingUIAction: (() -> Void)?

    private init() {
        let list: [any Skill] = [
            WeatherSkill(),
            WebSearchSkill(),
            MusicSkill(),
            ReminderSkill(),
            NotesSkill(),
            OpenAppSkill(),
            CameraSkill()
        ]
        self.skills = Dictionary(uniqueKeysWithValues: list.map { (type(of: $0).toolName, $0) })
    }

    // MARK: - Dispatch

    /// Executes a named tool call and returns a plain-text result for the AI.
    func execute(name: String, arguments: [String: Any]) async -> String {
        guard let skill = skills[name] else {
            return "Unknown function: \(name)"
        }

        // Reset skill state before execution
        skill.pendingUIAction = nil
        
        let result = await skill.execute(arguments: arguments)
        
        // Capture any deferred UI action (e.g., opening an app)
        self.pendingUIAction = skill.pendingUIAction
        
        return result
    }
}
