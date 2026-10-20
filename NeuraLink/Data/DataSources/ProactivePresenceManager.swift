//
//  ProactivePresenceManager.swift
//  NeuraLink
//
//  Time-based proactive engagement — Living Companion
//  (docs/LIVING_COMPANION.md). The companion speaks first:
//    • Trigger A — absence greeting: back after ≥ N hours → greet, delivering
//      the opener the reflection pipeline saved (Phase 1's payoff); falls
//      back to a generic warm greeting when no opener exists.
//    • Trigger B — silence small talk: quiet for ≥ M seconds mid-session →
//      one short in-character line, seeded with time-of-day, relationship
//      stage, and a random remembered fact. Max 2 per session, exponential
//      backoff, consecutive-duplicate dedupe.
//
//  Loop + guard structure mirrors ProactiveVisionManager, but engine-agnostic:
//  injects via sendInteractionEvent (OpenAI realtime) or handleUserInput
//  (local LLM) — the same seam song recognition uses.
//
//  Created by Dedicatus on 08/09/2026.
//

import Foundation
import UIKit
import WebRTC

final class ProactivePresenceManager {
    static let shared = ProactivePresenceManager()

    static let tickInterval: TimeInterval = 15
    static let maxSmallTalksPerSession = 2
    /// 90 s → 270 s (≈ the plan's "90 s → 5 min" backoff).
    static let smallTalkBackoffMultiplier = 3.0

    private var loopTask: Task<Void, Never>?
    private var observersInstalled = false

    /// Latched once per foreground stretch so the greeting can't repeat;
    /// reset when the app backgrounds (a long absence with the app still
    /// warm in memory must greet again).
    private var hasGreetedSinceForeground = false
    private var foregroundAt = Date()
    private var sessionReadyAt: Date?
    private var smallTalkCount = 0
    private var lastEngagementAt: Date?
    private var lastEventNormalized = ""
    /// Facts already woven into a small talk, so the next one leans on a
    /// different memory instead of the same "mock trial win" twice.
    private var usedFactSeeds: Set<String> = []

    private init() {}

    // MARK: - Lifecycle

    func startIfEnabled() {
        if PresenceSettings.shared.isProactiveEngagementEnabled { start() }
    }

    func start() {
        installObserversIfNeeded()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
        nlLog("[ProactivePresence] Started (tick \(Int(Self.tickInterval))s).", level: .info)
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        sessionReadyAt = nil
        nlLog("[ProactivePresence] Stopped.", level: .info)
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hasGreetedSinceForeground = false }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.foregroundAt = Date() }
        }
    }

    // MARK: - Tick

    private func tick() {
        guard PresenceSettings.shared.isProactiveEngagementEnabled else { return }
        guard UIApplication.shared.applicationState == .active || PiPManager.shared.isPiPActive
        else { return }

        let state = RealtimeChatState.shared
        guard state.status == .ready, !state.isUIHidden else { return }
        // Never talk over an in-flight song identification (mic is gated).
        guard SongRecognitionManager.shared.phase == .idle else { return }

        if sessionReadyAt == nil { sessionReadyAt = Date() }

        if maybeGreetAfterAbsence() { return }
        maybeSmallTalk()
    }

    // MARK: - Trigger A: absence greeting

    private func maybeGreetAfterAbsence() -> Bool {
        guard !hasGreetedSinceForeground else { return false }

        // Latch on every ineligible outcome — absence can't grow while the
        // app is open, so re-checking each tick is pointless.
        let clock = InteractionClock.shared
        guard let hours = clock.hoursSinceLastSeen,
            hours >= PresenceSettings.shared.absenceGreetingHours
        else {
            hasGreetedSinceForeground = true
            return false
        }
        // The user beat us to it this foreground stretch — no greeting.
        if let spokeAt = clock.lastUserSpeechAt, spokeAt > foregroundAt {
            hasGreetedSinceForeground = true
            return false
        }

        let character = RealtimeChatState.shared.selectedCharacterName
        let entry = MemoryStore.shared.latestUnusedOpener(character: character)
        let hour = Calendar.current.component(.hour, from: Date())
        let event = Self.greetingEvent(
            opener: entry?.opener,
            hoursAway: hours,
            timeOfDay: Self.timeOfDayDescriptor(hour: hour)
        )
        let japanese = Self.greetingEventJapanese(
            name: RealtimeChatState.shared.characterDisplayName, opener: entry?.opener,
            hoursAway: hours, timeOfDay: Self.timeOfDayJapanese(hour: hour))

        guard engage(with: event, japanese: japanese) else { return false }
        hasGreetedSinceForeground = true
        if let entry { MemoryStore.shared.markOpenerUsed(id: entry.id) }
        return true
    }

    // MARK: - Trigger B: silence small talk

    private func maybeSmallTalk() {
        guard smallTalkCount < Self.maxSmallTalksPerSession else { return }

        let clock = InteractionClock.shared
        let anchor = max(
            clock.lastUserSpeechAt ?? sessionReadyAt ?? Date(),
            lastEngagementAt ?? .distantPast
        )
        let silence = Date().timeIntervalSince(anchor)
        let required = Self.requiredSilence(
            base: PresenceSettings.shared.silenceSmallTalkSec,
            engagementsSoFar: smallTalkCount)
        guard silence >= required else { return }

        // A fact she hasn't used yet, a different angle each time, and her
        // own previous line to steer away from — the second silence of a
        // session must not get the same sentence as the first.
        let fact = MemoryStore.shared.fetchAllFacts()
            .map { "\($0.subject) \($0.predicate) \($0.object)" }
            .filter { !usedFactSeeds.contains($0) }
            .randomElement()
        let previousLine = Self.previousLine(RealtimeChatState.shared.aiTranscript)
        let hour = Calendar.current.component(.hour, from: Date())
        let angle = Self.smallTalkAngle(for: smallTalkCount)
        let event = Self.smallTalkEvent(
            timeOfDay: Self.timeOfDayDescriptor(hour: hour),
            stage: CompanionAffinity.compute().label,
            factSeed: fact,
            angle: angle,
            previousLine: previousLine
        )
        let japanese = Self.smallTalkEventJapanese(
            name: RealtimeChatState.shared.characterDisplayName,
            timeOfDay: Self.timeOfDayJapanese(hour: hour), angle: angle, previousLine: previousLine)

        let normalized = Self.normalize(event)
        guard normalized != lastEventNormalized else { return }

        guard engage(with: event, japanese: japanese) else { return }
        lastEventNormalized = normalized
        if let fact { usedFactSeeds.insert(fact) }
        smallTalkCount += 1
    }

    // MARK: - Engine-agnostic injection

    /// `japanese`: the same instruction for the Japanese local model (LLM-jp);
    /// without it the English goes in a short Japanese frame.
    @discardableResult
    func engage(with event: String, japanese: String? = nil) -> Bool {
        let openAI = OpenAISettings.shared
        if openAI.isEnabled && openAI.hasValidKey {
            guard OpenAIRealtimeManager.shared.remoteDataChannel?.readyState == .open
            else { return false }
            OpenAIRealtimeManager.shared.sendInteractionEvent(event)
        } else if openAI.isLocalLLMEnabled {
            // An instruction, not the user's words (LocalLLMManager+Cue).
            guard LocalLLMManager.shared.handleCue(LocalCue(english: event, japanese: japanese)) else { return false }
        } else {
            return false
        }
        lastEngagementAt = Date()
        nlLogSensitive("[ProactivePresence] Engaged: \(event.prefix(90))…", level: .info)
        return true
    }

    // MARK: - Pure helpers (unit-tested)

    nonisolated static func requiredSilence(base: Double, engagementsSoFar: Int) -> TimeInterval {
        base * pow(smallTalkBackoffMultiplier, Double(engagementsSoFar))
    }

    nonisolated static func timeOfDayDescriptor(hour: Int) -> String {
        switch hour {
        case 5..<9: return "early morning"
        case 9..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default: return "late night"
        }
    }

    nonisolated static func greetingEvent(opener: String?, hoursAway: Double, timeOfDay: String) -> String {
        let away = hoursAway >= 48
            ? "\(Int(hoursAway / 24)) days"
            : "\(Int(hoursAway)) hours"
        if let opener, !opener.isEmpty {
            return "*The user has returned after about \(away) away. It's \(timeOfDay). "
                + "Greet them warmly back in character, working in this thought you'd saved "
                + "for them: \"\(opener)\"*"
        }
        return "*The user has returned after about \(away) away. It's \(timeOfDay). "
            + "Greet them warmly back in character and ask what they've been up to.*"
    }

    nonisolated static func timeOfDayJapanese(hour: Int) -> String {
        switch hour {
        case 5..<9: return "早朝"
        case 9..<12: return "朝"
        case 12..<17: return "午後"
        case 17..<22: return "夕方"
        default: return "夜遅く"
        }
    }

    /// The return greeting for LLM-jp: short, imperative Japanese a 1.8B model
    /// follows instead of echoing. The saved opener only rides along when it is
    /// itself Japanese.
    nonisolated static func greetingEventJapanese(
        name: String, opener: String?, hoursAway: Double, timeOfDay: String
    ) -> String {
        let away = hoursAway >= 48 ? "\(Int(hoursAway / 24))日" : "\(Int(hoursAway))時間"
        var event = "相手が約\(away)ぶりに戻ってきました。今は\(timeOfDay)です。"
            + "\(name)として、温かく短い挨拶で迎えてください。"
        if let opener, isJapanese(opener) {
            event += "伝えたかった「\(opener.prefix(60))」という話も自然に入れてください。"
        } else {
            event += "最近どうしていたか聞いてください。"
        }
        return event
    }

    /// The silence break for LLM-jp, same two angles as the English one.
    nonisolated static func smallTalkEventJapanese(
        name: String, timeOfDay: String, angle: SmallTalkAngle, previousLine: String?
    ) -> String {
        var event: String
        switch angle {
        case .checkIn:
            event = "今は\(timeOfDay)で、しばらく会話が途切れています。\(name)として、自分から短く自然な一言で話しかけてください。"
                + "「まだいますか」とは聞かないでください。"
        case .shareThought:
            event = "今は\(timeOfDay)で、まだ静かです。\(name)として、自分のちょっとした考えや今日の小さな出来事を一言か二言で話してください。"
                + "質問は不要です。"
        }
        if let previousLine, !previousLine.isEmpty {
            event += "さっきは「\(previousLine.prefix(40))」と言ったので、違う言葉で別のことを話してください。"
        }
        return event
    }

    nonisolated static func isJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    /// What a small talk is for: the first one checks in, the next offers
    /// something of her own, so two silences never read the same.
    enum SmallTalkAngle: Int, CaseIterable, Sendable {
        case checkIn, shareThought
    }

    nonisolated static func smallTalkAngle(for engagementsSoFar: Int) -> SmallTalkAngle {
        SmallTalkAngle.allCases[max(0, engagementsSoFar) % SmallTalkAngle.allCases.count]
    }

    nonisolated static func smallTalkEvent(
        timeOfDay: String, stage: String, factSeed: String?,
        angle: SmallTalkAngle = .checkIn, previousLine: String? = nil
    ) -> String {
        var event: String
        switch angle {
        case .checkIn:
            event = "*The user has gone quiet for a while. It's \(timeOfDay) and your "
                + "relationship stage is \(stage). Break the silence in character with ONE short, "
                + "casual line — don't ask whether they're still there."
        case .shareThought:
            event = "*The user is still quiet. It's \(timeOfDay) and your relationship stage is "
                + "\(stage). Don't check in on them again — offer one small thing of your own instead: "
                + "a passing thought, something about this \(timeOfDay), or a tiny moment from your day, "
                + "in one or two short lines, no question needed."
        }
        if let factSeed, !factSeed.isEmpty {
            event += " If it feels natural, you could reference that \(factSeed)."
        }
        if let previousLine, !previousLine.isEmpty {
            event += " You already said: \"\(previousLine)\" — say something genuinely different, in different words."
        }
        event += "*"
        return event
    }

    /// Her last line, trimmed to one breath, for the anti-repeat clause.
    nonisolated static func previousLine(_ transcript: String, limit: Int = 160) -> String? {
        let flat = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// Lowercase, punctuation collapsed — consecutive-duplicate guard (same
    /// approach as ProactiveVisionManager's scene dedupe).
    nonisolated static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
