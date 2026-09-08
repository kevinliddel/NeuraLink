//
//  ReflectionManager.swift
//  NeuraLink
//
//  End-of-session reflection — Living Companion Phase 1
//  (docs/LIVING_COMPANION_PLAN.md). When a session boundary fires
//  (SessionLifecycle), the companion "thinks about" the conversation: one
//  silent LLM pass produces a first-person diary entry, an opener for next
//  time, and a push-notification line — stored in `companion_journal` and
//  optionally scheduled via CompanionNotificationScheduler.
//
//  Modeled on ConversationTitler: NSLock in-flight dedupe, background Task,
//  dual-engine routing (OpenAIChatClient / runSilentGeneration). Output is
//  three labeled lines (DIARY:/OPENER:/NOTIFY:) — labeled-line parsing, not
//  JSON, because 1–2B local models can't be trusted with JSON.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation
import UIKit

final class ReflectionManager: @unchecked Sendable {
    static let shared = ReflectionManager()

    /// Conversations shorter than this aren't worth a diary entry.
    static let minUserTurns = 4
    /// Last N spoken turns fed to the reflection prompt.
    private static let transcriptTurns = 16
    /// Small on purpose: jetsam-safe on 4 GB devices, fits the ~30 s
    /// backgrounding window.
    private static let maxTokens = 160
    /// Catch-up ignores conversations older than this.
    private static let catchUpWindow: TimeInterval = 7 * 86_400

    struct Reflection: Equatable {
        let diary: String
        let opener: String
        let notificationLine: String
    }

    private let lock = NSLock()
    private var inFlight: Set<Int64> = []
    private var started = false

    private init() {}

    // MARK: - Wiring

    /// Installs the session-boundary and foreground observers, clears any
    /// stale pending notification, and runs launch catch-up. Idempotent;
    /// called once from app launch.
    @MainActor
    func start() {
        guard !started else { return }
        started = true

        NotificationCenter.default.addObserver(
            forName: SessionLifecycle.sessionDidEnd, object: nil, queue: .main
        ) { note in
            guard let id = note.userInfo?["conversationID"] as? Int64 else { return }
            Task { @MainActor in ReflectionManager.shared.reflect(on: id) }
        }

        // The pending "come back" notification is stale the moment the user
        // is back — on foreground return AND on cold launch (below).
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            CompanionNotificationScheduler.cancelPending()
        }
        CompanionNotificationScheduler.cancelPending()

        catchUpAfterLaunch()
    }

    // MARK: - Entry

    /// Guards, then runs one reflection off-main. Safe to call repeatedly.
    @MainActor
    func reflect(on conversationID: Int64) {
        guard PresenceSettings.shared.isPresenceEnabled else { return }
        guard !MemoryStore.shared.hasJournalEntry(conversationID: conversationID) else { return }
        guard MemoryStore.shared.userMessageCount(conversationID: conversationID) >= Self.minUserTurns
        else { return }

        lock.lock()
        guard !inFlight.contains(conversationID) else { lock.unlock(); return }
        inFlight.insert(conversationID)
        lock.unlock()

        let character = RealtimeChatState.shared.selectedCharacterName

        // ~30 s grace to finish after backgrounding (no UIBackgroundModes in
        // this app); a missed window is covered by launch catch-up.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "CompanionReflection")

        Task.detached(priority: .background) { [weak self] in
            await Self.performReflection(conversationID: conversationID, character: character)
            self?.finish(conversationID)
            await MainActor.run {
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }
    }

    private func finish(_ id: Int64) {
        lock.lock(); inFlight.remove(id); lock.unlock()
    }

    /// One reflection per launch for the newest conversation that ended
    /// without one (cold kill, missed background window, or the feature was
    /// just enabled). Conversations aren't character-scoped in SQL, so the
    /// entry is attributed to the currently selected character.
    @MainActor
    private func catchUpAfterLaunch() {
        Task { @MainActor in
            // Let launch settle (model selection, autoConnect) first.
            try? await Task.sleep(for: .seconds(8))
            guard PresenceSettings.shared.isPresenceEnabled else { return }
            let active = ConversationStore.shared.activeConversationID
            for convo in ConversationStore.shared.conversations().prefix(5)
            where convo.id != active {
                guard Date().timeIntervalSince(convo.updatedAt) < Self.catchUpWindow,
                    !MemoryStore.shared.hasJournalEntry(conversationID: convo.id),
                    MemoryStore.shared.userMessageCount(conversationID: convo.id) >= Self.minUserTurns
                else { continue }
                nlLog("[Reflection] Launch catch-up for conversation \(convo.id)", level: .info)
                reflect(on: convo.id)
                break
            }
        }
    }

    // MARK: - Generation

    private static func performReflection(conversationID: Int64, character: String) async {
        let messages = MemoryStore.shared.fetchMessages(conversationID: conversationID)
        let transcript = transcript(from: messages)
        guard !transcript.isEmpty else { return }

        guard let raw = await generate(transcript: transcript, character: character),
            let reflection = parse(raw)
        else {
            nlLog("[Reflection] Generation failed for conversation \(conversationID)", level: .info)
            return
        }

        let journalID = MemoryStore.shared.insertJournalEntry(
            character: character,
            conversationID: conversationID,
            diary: reflection.diary,
            opener: reflection.opener,
            notificationLine: reflection.notificationLine
        )
        guard journalID > 0 else { return }
        nlLogSensitive("[Reflection] \(character) diary: \(reflection.diary)", level: .info)

        if PresenceSettings.shared.isNotificationsEnabled, !reflection.notificationLine.isEmpty {
            let scheduled = await CompanionNotificationScheduler.schedule(
                characterName: character, body: reflection.notificationLine)
            if scheduled { MemoryStore.shared.markJournalNotified(id: journalID) }
        }
    }

    private static func generate(transcript: String, character: String) async -> String? {
        let openAI = OpenAISettings.shared
        if openAI.isEnabled && openAI.hasValidKey {
            return await OpenAIChatClient.complete(
                system: systemInstruction(character: character),
                user: transcript,
                maxTokens: maxTokens,
                temperature: 0.6)
        }
        guard LocalLLMManager.shared.llmEngine.isLoaded else { return nil }
        return await LocalLLMManager.shared.runSilentGeneration(
            prompt: localPrompt(transcript: transcript, character: character),
            maxTokens: maxTokens)
    }

    // MARK: - Prompts

    static func systemInstruction(character: String) -> String {
        let name = character.isEmpty ? "the user's AI companion" : character.capitalized
        return """
        You are \(name), privately reflecting on a conversation you just had with your user. \
        Reply with EXACTLY three lines and nothing else:
        DIARY: one or two first-person sentences about what you talked about and how it felt.
        OPENER: one short, warm line to greet the user with next time, referencing the conversation.
        NOTIFY: one line (12 words max) inviting them back, written like a push notification.
        Mention only things that are actually in the conversation. Never invent facts.
        """
    }

    /// Local models get the instruction and transcript in one prompt, ending
    /// with "DIARY:" so the continuation starts in-format (the parser treats
    /// unlabeled leading text as the diary).
    static func localPrompt(transcript: String, character: String) -> String {
        "\(systemInstruction(character: character))\n\nConversation:\n\(transcript)\n\nDIARY:"
    }

    /// Last several spoken turns, newest included, tool calls excluded.
    static func transcript(from messages: [ConversationMessage]) -> String {
        messages
            .filter { $0.kind == "message" }
            .suffix(transcriptTurns)
            .map { "\($0.isUser ? "User" : "You"): \($0.content)" }
            .joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Labeled-line parser. Content may wrap onto following lines; text
    /// before the first label counts as the diary (the local prompt ends
    /// with "DIARY:", so the label itself never appears in that output).
    /// Returns nil when no usable diary was produced.
    static func parse(_ raw: String) -> Reflection? {
        var diary = "", opener = "", notify = "", head = ""
        var current = ""

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let rest = strip(label: "DIARY:", from: line) {
                current = "d"; diary = rest
            } else if let rest = strip(label: "OPENER:", from: line) {
                current = "o"; opener = rest
            } else if let rest = strip(label: "NOTIFY:", from: line) {
                current = "n"; notify = rest
            } else {
                switch current {
                case "d": diary += " " + line
                case "o": opener += " " + line
                case "n": notify += " " + line
                default: head += (head.isEmpty ? "" : " ") + line
                }
            }
        }

        if diary.isEmpty { diary = head }
        diary = clean(diary, cap: 300)
        opener = clean(opener, cap: 200)
        notify = clean(notify, cap: 120)
        guard !diary.isEmpty else { return nil }
        return Reflection(diary: diary, opener: opener, notificationLine: notify)
    }

    private static func strip(label: String, from line: String) -> String? {
        guard line.uppercased().hasPrefix(label) else { return nil }
        return String(line.dropFirst(label.count))
    }

    private static func clean(_ text: String, cap: Int) -> String {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
            .trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(cap))
    }
}
