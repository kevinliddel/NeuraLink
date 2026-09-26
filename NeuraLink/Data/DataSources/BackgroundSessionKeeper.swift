//
//  BackgroundSessionKeeper.swift
//  NeuraLink
//
//  Keeps a voice session alive when the app leaves the foreground
//  (docs/PRESENCE_BEYOND_APP_PLAN.md §P1). `UIBackgroundModes = audio` lets
//  the active audio session continue; this type decides whether it should
//  (opt-in toggle + engine state + battery guards), runs the idle watchdog,
//  posts the "still listening" notice, and reconnects on foreground return
//  after an idle disconnect.
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation
import UIKit
import UserNotifications

/// Pure keep-alive decision, testable without UIKit.
nonisolated struct BackgroundSessionPolicy: Sendable {
    enum Verdict: Equatable { case keepAlive, endSession }

    static let watchdogInterval: TimeInterval = 30

    /// Whether a session in `status` should survive backgrounding.
    static func onBackground(
        keepTalking: Bool, status: AIConnectionStatus, lowPower: Bool, thermal: ProcessInfo.ThermalState
    ) -> Verdict {
        guard keepTalking, !lowPower, thermal != .serious, thermal != .critical else { return .endSession }
        switch status {
        case .ready, .listening, .thinking, .speaking, .reconnecting: return .keepAlive
        default: return .endSession
        }
    }

    /// Whether a background session should be ended now.
    static func shouldEnd(
        idleSeconds: TimeInterval?, idleLimit: TimeInterval, lowPower: Bool, thermal: ProcessInfo.ThermalState,
        memoryWarning: Bool
    ) -> Bool {
        if lowPower || memoryWarning || thermal == .serious || thermal == .critical { return true }
        guard let idleSeconds else { return false }
        return idleSeconds >= idleLimit
    }
}

final class BackgroundSessionKeeper: @unchecked Sendable {
    static let shared = BackgroundSessionKeeper()

    static let noticeIdentifier = "com.neuralink.presence.backgroundListening"

    private var watchdog: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var memoryWarned = false
    /// Set when the keeper disconnected for battery reasons; the next
    /// foreground return reconnects automatically.
    private(set) var idleDisconnected = false
    private var observersInstalled = false

    private init() {}

    var isKeepingAlive: Bool { watchdog != nil }

    // MARK: - Decisions

    /// Called by SessionLifecycle on `didEnterBackground`. Returns true when
    /// the session is kept alive (the caller must then NOT post
    /// `sessionDidEnd`).
    @MainActor
    func beginBackgroundIfAllowed() -> Bool {
        let verdict = BackgroundSessionPolicy.onBackground(
            keepTalking: PresenceSettings.shared.keepTalkingInBackground,
            status: RealtimeChatState.shared.status,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: ProcessInfo.processInfo.thermalState)
        guard verdict == .keepAlive else { return false }
        installObservers()
        backgroundedAt = Date()
        memoryWarned = false
        startWatchdog()
        Self.postListeningNotice(characterName: RealtimeChatState.shared.selectedCharacterName)
        nlLog("[BackgroundSession] keeping the session alive in the background", level: .info)
        return true
    }

    /// Called on foreground return.
    @MainActor
    func didEnterForeground() {
        stopWatchdog()
        Self.cancelListeningNotice()
        guard idleDisconnected else { return }
        idleDisconnected = false
        let settings = OpenAISettings.shared
        if settings.isLocalLLMEnabled {
            LocalLLMManager.shared.startListening()
        } else if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.connect()
        }
        nlLog("[BackgroundSession] reconnected after idle disconnect", level: .info)
    }

    // MARK: - Watchdog

    @MainActor
    private func startWatchdog() {
        stopWatchdog()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BackgroundSessionPolicy.watchdogInterval))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    @MainActor
    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
        backgroundedAt = nil
    }

    @MainActor
    private func tick() {
        let clock = InteractionClock.shared
        // Idle counts from the last user speech, or from backgrounding when
        // the user never spoke this session.
        let idle = clock.secondsSinceUserSpoke ?? backgroundedAt.map { Date().timeIntervalSince($0) }
        let limit = PresenceSettings.shared.backgroundIdleMinutes * 60
        let shouldEnd = BackgroundSessionPolicy.shouldEnd(
            idleSeconds: idle, idleLimit: limit,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: ProcessInfo.processInfo.thermalState,
            memoryWarning: memoryWarned)
        if shouldEnd { endBackgroundSession(reason: idle.map { $0 >= limit } == true ? "backgroundIdle" : "backgroundGuard") }
    }

    /// Ends the session for battery / thermal / idle reasons: the reflection
    /// boundary fires now, engines disconnect, and the next foreground
    /// return reconnects.
    @MainActor
    func endBackgroundSession(reason: String) {
        guard isKeepingAlive else { return }
        stopWatchdog()
        Self.cancelListeningNotice()
        idleDisconnected = true
        nlLog("[BackgroundSession] ending session (\(reason))", level: .info)
        SessionLifecycle.shared.sessionEnded(reason: reason)
        let settings = OpenAISettings.shared
        if settings.isLocalLLMEnabled {
            LocalLLMManager.shared.suspendForBackground()
        } else {
            OpenAIRealtimeManager.shared.disconnect()
        }
    }

    // MARK: - Guards

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.memoryWarned = true
            Task { @MainActor in self.tick() }
        }
        center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    // MARK: - "Still listening" notice

    /// Until the Live Activity exists (P2), a local notification is the only
    /// visible sign that the microphone stays on in the background.
    static func postListeningNotice(characterName: String) {
        let content = UNMutableNotificationContent()
        let name = characterName.isEmpty ? "NeuraLink" : characterName.capitalized
        content.title = "\(name) is still listening"
        content.body = "The conversation continues in the background. Tap to return, or lock the mic from Autonomy settings."
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: noticeIdentifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request) { error in
            if let error { nlLog("[BackgroundSession] notice failed: \(error)", level: .warning) }
        }
    }

    static func cancelListeningNotice() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [noticeIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [noticeIdentifier])
    }
}
