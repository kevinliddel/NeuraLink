//
//  ReflectionManager.swift
//  NeuraLink
//
//  End-of-session reflection — Living Companion
//  (docs/LIVING_COMPANION.md). When a session boundary fires
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

    /// New user turns (since the last reflection) worth a diary entry.
    static let minUserTurns = 4
    /// Last N spoken turns fed to the reflection prompt.
    private static let transcriptTurns = 16
    /// Small on purpose: jetsam-safe on 4 GB devices, fits the ~30 s
    /// backgrounding window.
    private static let maxTokens = 240
    /// Catch-up ignores conversations older than this.
    private static let catchUpWindow: TimeInterval = 7 * 86_400

    struct Reflection: Equatable {
        let diary: String
        let opener: String
        let notificationLine: String
        /// NOTIFY2:/NOTIFY3: — later slots of the return series.
        var extraNotificationLines: [String] = []
        /// Optional distilled personality note (Phase 2). Empty when the
        /// conversation revealed nothing new.
        let trait: String
    }

    /// Trait pool bounds (Phase 2): at most this many per character; the
    /// weakest is evicted to admit a new one, and every reflection decays
    /// all weights so unused traits sink toward eviction.
    static let maxTraitsPerCharacter = 5
    static let traitDecayFactor = 0.95
    private static let traitLengthRange = 8...100

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
            Task { @MainActor in
                // The series goes out right away with the generic lines —
                // never hostage to the LLM reflection, which can fail or
                // outlive the ~30 s background window. A finished
                // reflection then re-schedules it with its own lines.
                ReflectionManager.shared.scheduleSeriesNow(conversationID: id)
                ReflectionManager.shared.reflect(on: id)
            }
        }

        // The pending "come back" notification is stale the moment the user
        // is back — on foreground return AND on cold launch (below). Log the
        // state BEFORE cancelling so "was one pending?" is answerable.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            CompanionNotificationScheduler.logDiagnostics(context: "foreground")
            CompanionNotificationScheduler.cancelPending()
        }
        CompanionNotificationScheduler.logDiagnostics(context: "launch")
        CompanionNotificationScheduler.cancelPending()
        // Foreground banner presentation (needed for the settings test button).
        CompanionNotificationPresenter.shared.install()

        catchUpAfterLaunch()
    }

    // MARK: - Entry

    /// Guards, then runs one reflection off-main. Safe to call repeatedly.
    @MainActor
    func reflect(on conversationID: Int64) {
        guard PresenceSettings.shared.isPresenceEnabled else { return }
        // New turns since the last reflection, not "ever reflected": the
        // active conversation survives backgrounding, so a once-only guard
        // meant one diary entry (and one notification) per chat, ever.
        guard MemoryStore.shared.unreflectedUserTurns(conversationID: conversationID) >= Self.minUserTurns
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
                    MemoryStore.shared.unreflectedUserTurns(conversationID: convo.id) >= Self.minUserTurns
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
            await scheduleReturnNotifications(conversationID: conversationID, reflection: nil)
            return
        }

        let journalID = MemoryStore.shared.insertJournalEntry(
            character: character,
            conversationID: conversationID,
            diary: reflection.diary,
            opener: reflection.opener,
            notificationLine: reflection.notificationLine,
            lastMessageID: messages.map(\.id).max() ?? 0
        )
        guard journalID > 0 else { return }
        nlLogSensitive("[Reflection] \(character) diary: \(reflection.diary)", level: .info)
        await MainActor.run { CompanionSnapshotWriter.shared.scheduleRefresh() }

        recordTrait(character: character, trait: reflection.trait)

        if await scheduleReturnNotifications(conversationID: conversationID, reflection: reflection) > 0 {
            MemoryStore.shared.markJournalNotified(id: journalID)
        }
    }

    /// Generic-line series under its own background-task grace, so iOS
    /// can't suspend the app before the requests are added.
    @MainActor
    func scheduleSeriesNow(conversationID: Int64) {
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "CompanionReturnSeries")
        Task {
            await Self.scheduleReturnNotifications(conversationID: conversationID, reflection: nil)
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
    }

    /// Schedules the return series when the user has actually left (never
    /// for launch catch-up while the app is open). Reflection lines lead,
    /// generic ones fill the rest; anchored on the conversation's last
    /// message. Returns how many notifications were scheduled.
    @discardableResult
    static func scheduleReturnNotifications(conversationID: Int64, reflection: Reflection?) async -> Int {
        guard PresenceSettings.shared.isPresenceEnabled, PresenceSettings.shared.isNotificationsEnabled else { return 0 }
        let isForeground = await MainActor.run { UIApplication.shared.applicationState == .active }
        guard !isForeground else { return 0 }
        let messages = MemoryStore.shared.fetchMessages(conversationID: conversationID)
        guard let lastExchange = messages.last(where: { $0.kind == "message" })?.timestamp,
              messages.contains(where: { $0.isUser && $0.kind == "message" })
        else {
            nlLog("[Presence] Return series skipped: no user messages in conversation \(conversationID)", level: .info)
            return 0
        }

        let userName = UserSettings.shared.name
        let lines = returnLines(reflection: reflection, userName: userName)
        let count = await CompanionNotificationScheduler.scheduleReturnSeries(
            characterName: RealtimeChatState.shared.selectedCharacterName, lines: lines, anchor: lastExchange)
        if count > 0 { CompanionNotificationScheduler.logDiagnostics(context: "scheduled") }
        return count
    }

    /// Conversational reflection lines first (deduped), then the generic pool.
    static func returnLines(reflection: Reflection?, userName: String) -> [String] {
        var lines: [String] = []
        let candidates = reflection.map { [$0.notificationLine] + $0.extraNotificationLines } ?? []
        for line in candidates where CompanionNotificationCopy.isConversational(line) && !lines.contains(line) {
            lines.append(line)
        }
        for line in CompanionNotificationCopy.genericLines(userName: userName) where !lines.contains(line) {
            lines.append(line)
        }
        return lines
    }

    private static func generate(transcript: String, character: String) async -> String? {
        let openAI = OpenAISettings.shared
        let userName = UserSettings.shared.name
        if openAI.isEnabled && openAI.hasValidKey {
            return await OpenAIChatClient.complete(
                system: systemInstruction(character: character, userName: userName),
                user: transcript,
                maxTokens: maxTokens,
                temperature: 0.6,
                purpose: "reflection")
        }
        guard LocalLLMManager.shared.llmEngine.isLoaded else { return nil }
        return await LocalLLMManager.shared.runSilentGeneration(
            prompt: localPrompt(transcript: transcript, character: character, userName: userName),
            maxTokens: maxTokens)
    }

    // MARK: - Prompts

    static func systemInstruction(character: String, userName: String = "") -> String {
        let name = character.isEmpty ? "the user's AI companion" : character.capitalized
        let user = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = user.isEmpty ? "your user" : user
        return """
        You are \(name), privately reflecting on a conversation you just had with \(who). \
        Reply with EXACTLY these labeled lines and nothing else:
        DIARY: one or two first-person sentences about what you talked about and how it felt.
        OPENER: one short, warm line to greet \(who) with next time, referencing the conversation.
        NOTIFY: one or two short sentences (25 words max) sent to \(who) as a phone notification — \
        a warm, conversational message in your own voice that picks up something specific from the \
        conversation and invites them back. Address them directly, never as "the user".
        NOTIFY2: a different notification for two hours later if they still haven't come back — \
        same rules, new angle, never repeating NOTIFY.
        NOTIFY3: another one for later still — same rules, different again.
        TRAIT: one short note about the user's habits or your dynamic with them — ONLY if the \
        conversation clearly revealed something new; otherwise omit this line entirely.
        Mention only things that are actually in the conversation. Never invent facts.
        """
    }

    /// Local models get the instruction and transcript in one prompt, ending
    /// with "DIARY:" so the continuation starts in-format (the parser treats
    /// unlabeled leading text as the diary).
    static func localPrompt(transcript: String, character: String, userName: String = "") -> String {
        "\(systemInstruction(character: character, userName: userName))\n\nConversation:\n\(transcript)\n\nDIARY:"
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
        var diary = "", opener = "", notify = "", notify2 = "", notify3 = "", trait = "", head = ""
        var current = ""

        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let rest = strip(label: "DIARY:", from: line) {
                current = "d"; diary = rest
            } else if let rest = strip(label: "OPENER:", from: line) {
                current = "o"; opener = rest
            } else if let rest = strip(label: "NOTIFY2:", from: line) {
                current = "n2"; notify2 = rest
            } else if let rest = strip(label: "NOTIFY3:", from: line) {
                current = "n3"; notify3 = rest
            } else if let rest = strip(label: "NOTIFY:", from: line) {
                current = "n"; notify = rest
            } else if let rest = strip(label: "TRAIT:", from: line) {
                current = "t"; trait = rest
            } else {
                switch current {
                case "d": diary += " " + line
                case "o": opener += " " + line
                case "n": notify += " " + line
                case "n2": notify2 += " " + line
                case "n3": notify3 += " " + line
                case "t": trait += " " + line
                default: head += (head.isEmpty ? "" : " ") + line
                }
            }
        }

        if diary.isEmpty { diary = head }
        diary = clean(diary, cap: 300)
        opener = clean(opener, cap: 200)
        let notifyCap = CompanionNotificationCopy.lengthRange.upperBound
        notify = clean(notify, cap: notifyCap)
        let extras = [clean(notify2, cap: notifyCap), clean(notify3, cap: notifyCap)].filter { !$0.isEmpty }
        trait = clean(trait, cap: 100)
        guard !diary.isEmpty else { return nil }
        return Reflection(
            diary: diary, opener: opener, notificationLine: notify, extraNotificationLines: extras, trait: trait)
    }

    // MARK: - Trait pool (Phase 2)

    /// Admits a distilled trait into the character's capped pool:
    /// decay all → bump an existing match → else evict the weakest when
    /// full → insert fresh. Rejects junk (too short/long).
    static func recordTrait(character: String, trait: String) {
        guard !character.isEmpty, traitLengthRange.contains(trait.count) else { return }
        let store = MemoryStore.shared

        // Unused traits sink a little on every reflection.
        store.decayTraits(character: character, factor: traitDecayFactor)

        let existing = store.traits(character: character, limit: maxTraitsPerCharacter * 2)
        if let match = existing.first(where: { $0.trait.caseInsensitiveCompare(trait) == .orderedSame }) {
            store.upsertTrait(character: character, trait: trait, weight: match.weight + 1.0)
            return
        }
        if existing.count >= maxTraitsPerCharacter,
            let weakest = existing.min(by: { $0.weight < $1.weight }) {
            store.deleteTrait(id: weakest.id)
        }
        store.upsertTrait(character: character, trait: trait, weight: 1.0)
        nlLogSensitive("[Reflection] \(character) trait: \(trait)", level: .info)
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
