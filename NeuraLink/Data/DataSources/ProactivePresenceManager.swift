//
//  ProactivePresenceManager.swift
//  NeuraLink
//
//  Time-based proactive engagement — Living Companion Phase 3
//  (docs/LIVING_COMPANION_PLAN.md §⑥). The companion speaks first:
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
        let event = Self.greetingEvent(
            opener: entry?.opener,
            hoursAway: hours,
            timeOfDay: Self.timeOfDayDescriptor(hour: Calendar.current.component(.hour, from: Date()))
        )

        guard engage(with: event) else { return false }
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

        let fact = MemoryStore.shared.fetchAllFacts().randomElement()
            .map { "\($0.subject) \($0.predicate) \($0.object)" }
        let event = Self.smallTalkEvent(
            timeOfDay: Self.timeOfDayDescriptor(hour: Calendar.current.component(.hour, from: Date())),
            stage: CompanionAffinity.compute().label,
            factSeed: fact
        )

        let normalized = Self.normalize(event)
        guard normalized != lastEventNormalized else { return }

        guard engage(with: event) else { return }
        lastEventNormalized = normalized
        smallTalkCount += 1
    }

    // MARK: - Engine-agnostic injection

    @discardableResult
    private func engage(with event: String) -> Bool {
        let openAI = OpenAISettings.shared
        if openAI.isEnabled && openAI.hasValidKey {
            guard OpenAIRealtimeManager.shared.remoteDataChannel?.readyState == .open
            else { return false }
            OpenAIRealtimeManager.shared.sendInteractionEvent(event)
        } else if openAI.isLocalLLMEnabled {
            guard LocalLLMManager.shared.llmEngine.isLoaded else { return false }
            LocalLLMManager.shared.handleUserInput(event, logToTimeline: false)
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

    nonisolated static func smallTalkEvent(timeOfDay: String, stage: String, factSeed: String?) -> String {
        var event = "*The user has gone quiet for a while. It's \(timeOfDay) and your "
            + "relationship stage is \(stage). Break the silence in character with ONE short, "
            + "casual line — don't ask whether they're still there."
        if let factSeed, !factSeed.isEmpty {
            event += " If it feels natural, you could reference that \(factSeed)."
        }
        event += "*"
        return event
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
