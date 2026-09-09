//
//  PlayGameSkill.swift
//  NeuraLink
//
//  Play a quick game together (20 Questions, Trivia, Word Chain) — Living
//  Companion Phase 4b. The skill is a thin gate onto GameSessionManager,
//  which owns the rules, the turn count, and (for 20 Questions) the secret.
//
//  Created by Dedicatus on 09/09/2026.
//

import Foundation

@MainActor
final class PlayGameSkill: Skill {
    static let toolName = AppFunctionTool.playGame
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        if (arguments["action"] as? String) == "stop" {
            return GameSessionManager.shared.stop()
                ?? "No game is running right now."
        }
        guard let raw = arguments["game"] as? String,
            let kind = GameKind(rawValue: raw)
        else {
            let available = GameKind.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unknown game. Available games: \(available)."
        }
        return GameSessionManager.shared.start(kind)
    }
}
