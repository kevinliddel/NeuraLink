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
            CameraSkill(),
            RememberFactSkill(),
            PhotoshootSkill(),
            IdentifySongSkill(),
            PlayGameSkill()
        ]
        self.skills = Dictionary(uniqueKeysWithValues: list.map { (type(of: $0).toolName, $0) })
    }

    // MARK: - Dispatch

    /// Executes a named tool call and returns a plain-text result for the AI.
    func execute(name: String, arguments: [String: Any]) async -> String {
        let argsPreview = (try? JSONSerialization.data(withJSONObject: arguments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(arguments)"
        nlLog("֎ [FunctionCall] dispatch name=\(name) args=\(argsPreview)", level: .info)

        guard let skill = skills[name] else {
            nlLog("֎ [FunctionCall] UNKNOWN tool '\(name)' — registered: \(skills.keys.sorted())", level: .error)
            return "Unknown function: \(name)"
        }

        // Reset skill state before execution
        skill.pendingUIAction = nil

        let result = await skill.execute(arguments: arguments)

        // Capture any deferred UI action (e.g., opening an app). Tools with
        // a phone card don't auto-open anymore: after the AI finishes
        // speaking, the companion's phone widget slides in and the ACTUAL
        // open happens when the user taps it (GTA-style, no app-yanking).
        let card = PhoneWidgetManager.card(for: name, arguments: arguments, result: result)
        if let action = skill.pendingUIAction {
            if let card {
                self.pendingUIAction = {
                    Task { @MainActor in
                        PhoneWidgetManager.shared.present(card: card, action: action)
                    }
                }
            } else {
                self.pendingUIAction = action
            }
        } else if let card {
            // Display-only phone (weather): the screen IS the payload —
            // nothing opens on tap, it just rides the same after-speech timing.
            self.pendingUIAction = {
                Task { @MainActor in
                    PhoneWidgetManager.shared.present(card: card, action: nil)
                }
            }
        } else {
            self.pendingUIAction = nil
        }

        let resultPreview = result.count > 200 ? String(result.prefix(200)) + "…" : result
        nlLog(
            "֎ [FunctionCall] done name=\(name) result=\"\(resultPreview)\""
            + (self.pendingUIAction != nil ? " (deferred UI action queued)" : ""),
            level: .info
        )
        return result
    }
}
