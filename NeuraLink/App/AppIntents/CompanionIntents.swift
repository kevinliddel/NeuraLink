//
//  CompanionIntents.swift
//  NeuraLink
//
//  Siri + App Shortcuts (docs/PRESENCE_BEYOND_APP_PLAN.md §P4): start a
//  conversation with a character, ask the companion's memory a question
//  without opening the app, and store a fact by voice. Lives in the app
//  target — no extension needed.
//
//  Created by Dedicatus on 27/09/2026.
//

import AppIntents
import Foundation

// MARK: - Cross-launch request

/// What an intent asked the running app to do. ContentView observes
/// `pendingCharacter` and switches the scene; a cold launch reads
/// `UserSettings.selectedCharacter` instead.
@Observable
final class AppIntentRequests {
    static let shared = AppIntentRequests()
    var pendingCharacter: String?
    private init() {}
}

// MARK: - Character entity

struct CharacterEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Character")
    static let defaultQuery = CharacterQuery()

    /// Registry name (built-in stem or imported slug), lowercased.
    let id: String
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }

    /// Case-insensitive match on id or display name; used by the query and
    /// by tests.
    static func matches(_ entry: (name: String, displayName: String), _ text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        return entry.name.lowercased() == needle || entry.displayName.lowercased() == needle
            || entry.displayName.lowercased().hasPrefix(needle)
    }
}

struct CharacterQuery: EntityStringQuery {
    @MainActor
    private func all() -> [CharacterEntity] {
        VRMModelRegistry.shared.all.map { CharacterEntity(id: $0.name.lowercased(), displayName: $0.displayName) }
    }

    func entities(for identifiers: [String]) async throws -> [CharacterEntity] {
        let wanted = Set(identifiers.map { $0.lowercased() })
        return await all().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [CharacterEntity] {
        await all().filter { CharacterEntity.matches((name: $0.id, displayName: $0.displayName), string) }
    }

    func suggestedEntities() async throws -> [CharacterEntity] {
        await all()
    }
}

// MARK: - Talk to a character

struct TalkToCompanionIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to a character"
    static let description = IntentDescription("Opens NeuraLink and starts a voice conversation.")
    static let openAppWhenRun = true

    @Parameter(title: "Character")
    var character: CharacterEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        if let character {
            UserSettings.shared.selectedCharacter = character.id
            AppIntentRequests.shared.pendingCharacter = character.id
        }
        return .result()
    }
}

// MARK: - Ask memory

struct AskMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask memory"
    static let description = IntentDescription("Answers a question from what your companion remembers, without opening the app.")

    static let timeout: Duration = .seconds(8)
    static let nothingKnown = "I don't have anything about that yet."

    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard MemorySettings.shared.isEnabled else {
            return .result(dialog: "Memory is turned off in NeuraLink.")
        }
        let character = RealtimeChatState.shared.selectedCharacterName.isEmpty
            ? (UserSettings.shared.selectedCharacter ?? "")
            : RealtimeChatState.shared.selectedCharacterName
        let answer = await IntentTimeout.run(timeout: Self.timeout) {
            await MemoryReflect.shared.reflect(question: question, character: character)
        }
        return .result(dialog: IntentDialog(stringLiteral: answer ?? Self.nothingKnown))
    }
}

// MARK: - Remember

struct RememberIntent: AppIntent {
    static let title: LocalizedStringResource = "Remember something"
    static let description = IntentDescription("Stores a fact in your companion's memory.")

    @Parameter(title: "Fact")
    var fact: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard MemorySettings.shared.isEnabled else {
            return .result(dialog: "Memory is turned off in NeuraLink.")
        }
        let text = Self.normalise(fact)
        let id = MemoryRetain.shared.retainFact(ExtractedFact(text: text), source: "siri")
        guard id > 0 else { return .result(dialog: "That was too short to remember.") }
        OpenAIRealtimeManager.postInstructionsChanged(reason: "siri remember")
        return .result(dialog: "Got it. I'll remember that \(Self.spoken(text))")
    }

    /// Siri dictation gives first person ("my dentist is on Friday"); memory
    /// facts are third person about the user.
    static func normalise(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacements: [(String, String)] = [
            ("^i am ", "User is "), ("^i'm ", "User is "), ("^i ", "User "), ("^my ", "User's "),
            ("^we ", "User and others "), ("^mine ", "User's ")
        ]
        for (pattern, replacement) in replacements
        where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
            break
        }
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        if !text.hasSuffix(".") { text += "." }
        return text
    }

    /// Spoken confirmation reads better in second person.
    static func spoken(_ fact: String) -> String {
        fact.replacingOccurrences(of: "User's ", with: "your ")
            .replacingOccurrences(of: "User is ", with: "you are ")
            .replacingOccurrences(of: "User ", with: "you ")
    }
}

// MARK: - Timeout helper

enum IntentTimeout {
    /// Runs `operation`, returning nil if it exceeds `timeout` so Siri never hangs.
    static func run<T: Sendable>(timeout: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Shortcuts

struct NeuraLinkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToCompanionIntent(),
            phrases: [
                "Talk to \(\.$character) in \(.applicationName)",
                "Open \(.applicationName) and talk to \(\.$character)",
                "Start a conversation in \(.applicationName)"
            ],
            shortTitle: "Talk",
            systemImageName: "waveform")
        AppShortcut(
            intent: AskMemoryIntent(),
            phrases: [
                "Ask \(.applicationName) what I said",
                "Ask \(.applicationName) about my memories"
            ],
            shortTitle: "Ask memory",
            systemImageName: "brain.head.profile")
        AppShortcut(
            intent: RememberIntent(),
            phrases: [
                "Remember this in \(.applicationName)",
                "Tell \(.applicationName) to remember something"
            ],
            shortTitle: "Remember",
            systemImageName: "checkmark.seal")
    }
}
