//
//  GameSessionTests.swift
//  NeuraLinkTests
//
//  Living Companion Phase 4b: the mini-games state machine — lifecycle,
//  the code-held 20 Questions secret, turn caps, and the tool schema.
//  GameSessionManager is a singleton: every test stops any running game
//  first and cleans up after itself.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Mini-Games Session", .serialized)
struct GameSessionTests {

    private func reset() {
        _ = GameSessionManager.shared.stop()
    }

    // MARK: - Lifecycle

    @Test("Start returns the rules brief and activates the game")
    func startActivates() {
        reset()
        defer { reset() }

        let brief = GameSessionManager.shared.start(.trivia)
        #expect(GameSessionManager.shared.isGameActive)
        #expect(GameSessionManager.shared.activeGame == .trivia)
        #expect(brief.contains("Trivia"))
        #expect(brief.contains("score"))
    }

    @Test("Stop deactivates and returns a wrap-up; double-stop returns nil")
    func stopDeactivates() {
        reset()
        _ = GameSessionManager.shared.start(.wordChain)

        let wrapUp = GameSessionManager.shared.stop()
        #expect(wrapUp?.contains("Word Chain") == true)
        #expect(!GameSessionManager.shared.isGameActive)
        #expect(GameSessionManager.shared.stop() == nil)
    }

    @Test("Starting a new game replaces the running one and resets turns")
    func restartReplaces() {
        reset()
        defer { reset() }

        _ = GameSessionManager.shared.start(.trivia)
        GameSessionManager.shared.noteTurn()
        _ = GameSessionManager.shared.start(.wordChain)

        #expect(GameSessionManager.shared.activeGame == .wordChain)
        #expect(GameSessionManager.shared.promptReminder().contains("Turn 0"))
    }

    // MARK: - The code-held secret

    @Test("20 Questions carries the secret in brief and every reminder")
    func secretInjection() {
        reset()
        defer { reset() }

        let brief = GameSessionManager.shared.start(.twentyQuestions, secret: "a lighthouse")
        #expect(brief.contains("a lighthouse"))

        GameSessionManager.shared.noteTurn()
        let reminder = GameSessionManager.shared.promptReminder()
        #expect(reminder.contains("a lighthouse"))
        #expect(reminder.contains("NEVER say it"))
        #expect(reminder.contains("Turn 1"))
    }

    @Test("Non-secret games never leak a secret line")
    func noSecretForTrivia() {
        reset()
        defer { reset() }

        _ = GameSessionManager.shared.start(.trivia, secret: "a lighthouse")
        #expect(!GameSessionManager.shared.promptReminder().contains("lighthouse"))
    }

    // MARK: - Turn caps

    @Test("Reminder nudges a finish at the soft cap")
    func softCapNudge() {
        reset()
        defer { reset() }

        _ = GameSessionManager.shared.start(.trivia)
        for _ in 0..<GameKind.trivia.maxTurns { GameSessionManager.shared.noteTurn() }
        #expect(GameSessionManager.shared.isGameActive)
        #expect(GameSessionManager.shared.promptReminder().contains("end it now"))
    }

    @Test("Hard cap self-ends a forgotten game")
    func hardCapAutoEnd() {
        reset()
        defer { reset() }

        _ = GameSessionManager.shared.start(.trivia)
        let hardCap = GameKind.trivia.maxTurns + GameSessionManager.hardCapGrace + 1
        for _ in 0..<hardCap { GameSessionManager.shared.noteTurn() }
        #expect(!GameSessionManager.shared.isGameActive)
        #expect(GameSessionManager.shared.promptReminder().isEmpty)
    }

    @Test("Reminder is empty with no game running")
    func emptyReminderWhenIdle() {
        reset()
        #expect(GameSessionManager.shared.promptReminder().isEmpty)
    }

    // MARK: - Tool schema

    @Test("play_game schema lists every GameKind and both actions")
    func toolSchema() {
        let tool = AppFunctionTool.all.first {
            ($0["name"] as? String) == AppFunctionTool.playGame
        }
        let parameters = tool?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]

        let gameEnum = (properties?["game"] as? [String: Any])?["enum"] as? [String]
        for kind in GameKind.allCases {
            #expect(gameEnum?.contains(kind.rawValue) == true)
        }
        let actionEnum = (properties?["action"] as? [String: Any])?["enum"] as? [String]
        #expect(actionEnum?.contains("stop") == true)
    }

    // MARK: - Skill dispatch

    @Test("Executor routes play_game start and stop")
    @MainActor
    func skillDispatch() async {
        reset()
        defer { reset() }

        let started = await AppFunctionExecutor.shared.execute(
            name: AppFunctionTool.playGame, arguments: ["game": "twenty_questions"])
        #expect(started.contains("20 Questions"))
        #expect(GameSessionManager.shared.isGameActive)

        let stopped = await AppFunctionExecutor.shared.execute(
            name: AppFunctionTool.playGame, arguments: ["action": "stop"])
        #expect(stopped.contains("over"))
        #expect(!GameSessionManager.shared.isGameActive)

        let unknown = await AppFunctionExecutor.shared.execute(
            name: AppFunctionTool.playGame, arguments: ["game": "chess"])
        #expect(unknown.contains("Unknown game"))
    }
}
