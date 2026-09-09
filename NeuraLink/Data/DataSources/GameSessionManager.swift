//
//  GameSessionManager.swift
//  NeuraLink
//
//  Mini-games state machine — Living Companion Phase 4b
//  (docs/LIVING_COMPANION_PLAN.md §④). The rules live HERE, not in the
//  model: the manager owns which game is running, the turn count, the
//  turn-cap wrap-up nudge, and — critically for 20 Questions — the secret
//  answer. A conversational LLM has no hidden state (everything it "thinks"
//  is in the transcript), so code picks the secret and re-injects it
//  privately into every turn's prompt reminder.
//
//  Thread-safe the ConversationStore way (NSLock + @unchecked Sendable):
//  read from the local generation Task, the OpenAI handlers, and the
//  MainActor skill without isolation hops.
//
//  Created by Dedicatus on 09/09/2026.
//

import Foundation

/// The games the persona can host.
enum GameKind: String, CaseIterable {
    case twentyQuestions = "twenty_questions"
    case trivia
    case wordChain = "word_chain"

    var displayName: String {
        switch self {
        case .twentyQuestions: return "20 Questions"
        case .trivia: return "Trivia"
        case .wordChain: return "Word Chain"
        }
    }

    /// Soft cap: past this the per-turn reminder tells the model to steer
    /// the game to a finish.
    var maxTurns: Int {
        switch self {
        case .twentyQuestions: return 20
        case .trivia: return 10
        case .wordChain: return 15
        }
    }
}

final class GameSessionManager: @unchecked Sendable {
    static let shared = GameSessionManager()

    /// Game turns get more room than the usual spoken-reply cap (60): a
    /// trivia question + options, or a wrap-up with the reveal, doesn't fit
    /// in 15 seconds of speech but must not be cut mid-sentence either.
    static let gameTurnMaxTokens = 120

    /// Hard stop: this many turns past the soft cap and the session
    /// deactivates itself even if nobody said "stop".
    static let hardCapGrace = 5

    private let lock = NSLock()
    private var _activeGame: GameKind?
    private var _turnCount = 0
    private var _secret = ""

    private init() {}

    // MARK: - State

    var activeGame: GameKind? {
        lock.withLock { _activeGame }
    }

    var isGameActive: Bool {
        lock.withLock { _activeGame != nil }
    }

    // MARK: - Lifecycle

    /// Starts (or switches to) a game and returns the AI-facing rules brief —
    /// the tool result the model acts on. `secret` is injectable for tests;
    /// normally the manager draws one.
    func start(_ game: GameKind, secret: String? = nil) -> String {
        let chosenSecret = secret ?? Self.twentyQuestionsSecrets.randomElement() ?? "a cat"
        lock.withLock {
            _activeGame = game
            _turnCount = 0
            _secret = game == .twentyQuestions ? chosenSecret : ""
        }
        nlLog("[Game] Started \(game.displayName).", level: .info)
        return Self.rulesBrief(for: game, secret: chosenSecret)
    }

    /// Ends the running game. Returns the wrap-up instruction for the AI,
    /// or nil when nothing was running.
    func stop() -> String? {
        let ended: GameKind? = lock.withLock {
            let game = _activeGame
            _activeGame = nil
            _turnCount = 0
            _secret = ""
            return game
        }
        guard let ended else { return nil }
        nlLog("[Game] Stopped \(ended.displayName).", level: .info)
        return "The \(ended.displayName) game is over. Give a short, fun wrap-up in character "
            + "— the score or the answer if there was one — then chat normally again."
    }

    /// Counts a real user turn; past the hard cap the session self-ends so a
    /// forgotten game can't inflate every reply's token budget forever.
    func noteTurn() {
        let expired: GameKind? = lock.withLock {
            guard let game = _activeGame else { return nil }
            _turnCount += 1
            if _turnCount > game.maxTurns + Self.hardCapGrace {
                _activeGame = nil
                _turnCount = 0
                _secret = ""
                return game
            }
            return nil
        }
        if let expired {
            nlLog("[Game] \(expired.displayName) hit the hard turn cap — auto-ended.", level: .info)
        }
    }

    // MARK: - Prompt reminder

    /// Per-turn system block keeping a small model on the rails mid-game:
    /// which game, the turn number, the secret (20Q), and the wrap-up nudge
    /// near the cap. Rides AFTER history with the facts block, so the
    /// KV-cache prefix stays untouched. Empty when no game runs.
    func promptReminder() -> String {
        let (game, turns, secret): (GameKind?, Int, String) = lock.withLock {
            (_activeGame, _turnCount, _secret)
        }
        guard let game else { return "" }

        var out = "\n[Active Game: \(game.displayName)]\n"
        out += "- Turn \(turns) of ~\(game.maxTurns). Stay in the game — every reply serves it.\n"
        if game == .twentyQuestions {
            out += "- Your secret answer is \"\(secret)\". NEVER say it unless the user guesses "
                + "it or the game ends. Answer their questions only with yes / no / sort of.\n"
        }
        if turns >= game.maxTurns {
            out += "- The game has reached its turn limit: announce the result and end it now.\n"
        }
        out += "[End Game]\n"
        return out
    }

    // MARK: - Rules

    static func rulesBrief(for game: GameKind, secret: String) -> String {
        switch game {
        case .twentyQuestions:
            return "You're now hosting 20 Questions! Your SECRET answer is \"\(secret)\" — never "
                + "say it aloud unless the user guesses it or the questions run out. The user asks "
                + "yes/no questions; answer only \"yes\", \"no\", or \"sort of\", and keep count. "
                + "Announce the game and invite their first question."
        case .trivia:
            return "You're now hosting a Trivia game! Ask ONE general-knowledge question at a "
                + "time (no multiple parts), wait for the user's answer, say if it's right, and "
                + "keep a running score out of 5 questions. Announce the game and ask question 1."
        case .wordChain:
            return "You're now playing Word Chain! Each word must start with the LAST letter of "
                + "the previous word; no repeats. You and the user alternate — if a word breaks "
                + "the rule, call it out playfully. Announce the game and say the first word."
        }
    }

    /// Common, guessable secrets for 20 Questions — concrete nouns a yes/no
    /// path can reach.
    static let twentyQuestionsSecrets: [String] = [
        "a cat", "a bicycle", "an umbrella", "a piano", "a penguin",
        "a lighthouse", "a strawberry", "a snowman", "a guitar", "a dolphin",
        "a hot air balloon", "a toothbrush", "a campfire", "a windmill",
        "a robot", "a rainbow", "a pillow", "a sunflower", "a submarine",
        "a teapot", "an owl", "a ferris wheel", "a cactus", "a kite"
    ]
}
