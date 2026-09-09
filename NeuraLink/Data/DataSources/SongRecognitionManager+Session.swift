//
//  SongRecognitionManager+Session.swift
//  NeuraLink
//
//  Co-listening ("listen together") session — Living Companion Phase 4a
//  (docs/LIVING_COMPANION_PLAN.md §④). The one-shot recognition becomes a
//  loop: re-arm ShazamKit periodically, keep the current track on the
//  nav-bar capsule, and have the persona chime in when the track changes.
//
//  Etiquette / battery rules:
//    • auto-stops after 30 min, on backgrounding, on headphone (un)plug,
//      or below 20% battery (unplugged),
//    • one persona comment per track change, ≥ 60 s apart,
//    • never opens a capture window while the persona is mid-turn.
//
//  Entry points: long-press on the Identify Song FAB, or the
//  `identify_song` tool with `"mode": "session"`.
//
//  Created by Dedicatus on 09/09/2026.
//

import AVFAudio
import Foundation
import ShazamKit
import UIKit

extension SongRecognitionManager {

    static let sessionMaxDuration: TimeInterval = 30 * 60
    /// Re-arm delay after a successful match (the track is known — no rush).
    static let sessionMatchedInterval: TimeInterval = 75
    /// Re-arm delay after a miss (still hunting for the current track).
    static let sessionRetryInterval: TimeInterval = 20
    static let sessionCommentCooldown: TimeInterval = 60
    static let sessionBatteryFloor: Float = 0.2
    /// Consecutive hard failures before the session gives up.
    static let sessionMaxFailureStreak = 3

    // MARK: - Lifecycle

    /// Starts a listening-together session. No-ops while any recognition is
    /// already running.
    func startSession() {
        guard !isSessionActive, managedSession == nil else { return }
        isSessionActive = true
        sessionStartedAt = Date()
        lastTrackKey = ""
        lastCommentAt = .distantPast
        sessionFailureStreak = 0
        UIDevice.current.isBatteryMonitoringEnabled = true
        installSessionObservers()
        nlLog("[SongID] Co-listening session started.", level: .info)
        sessionTask = Task { [weak self] in await self?.runSession() }
    }

    /// Ends the session and restores everything. Safe to call repeatedly.
    func stopSession(reason: String) {
        guard isSessionActive else { return }
        isSessionActive = false
        sessionTask?.cancel()
        sessionTask = nil
        managedSession?.cancel()
        removeSessionObservers()
        UIDevice.current.isBatteryMonitoringEnabled = false
        sessionStartedAt = nil
        setPhase(.idle)
        nlLog("[SongID] Co-listening session stopped (\(reason)).", level: .info)
    }

    // MARK: - Loop

    private func runSession() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            stopSession(reason: "permission")
            setPhase(.failed("Microphone access is required to identify songs."))
            return
        }
        setPhase(.listening)

        while !Task.isCancelled && isSessionActive {
            if let startedAt = sessionStartedAt,
                Self.hasExceededDuration(startedAt: startedAt, now: Date()) {
                stopSession(reason: "30-minute cap")
                return
            }
            if Self.isBatteryCritical(
                level: UIDevice.current.batteryLevel, state: UIDevice.current.batteryState) {
                stopSession(reason: "low battery")
                return
            }

            // Never yank the audio units out from under the persona mid-turn.
            await waitUntilPipelineIdle()
            guard !Task.isCancelled && isSessionActive else { return }

            let suspendedLocalCapture = beginCaptureWindow()
            let outcome = await listenOnce()
            endCaptureWindow(suspendedLocalCapture: suspendedLocalCapture)
            guard !Task.isCancelled && isSessionActive else { return }

            var interval = Self.sessionRetryInterval
            switch outcome {
            case .matched(let song):
                sessionFailureStreak = 0
                interval = Self.sessionMatchedInterval
                handleSessionMatch(song)
            case .noMatch:
                sessionFailureStreak = 0
            case .failed(let message):
                sessionFailureStreak += 1
                nlLog(
                    "[SongID] Session attempt failed (\(sessionFailureStreak)/\(Self.sessionMaxFailureStreak)): \(message)",
                    level: .warning)
                if sessionFailureStreak >= Self.sessionMaxFailureStreak {
                    stopSession(reason: "repeated failures")
                    setPhase(.failed(message))
                    return
                }
            }

            try? await Task.sleep(for: .seconds(interval))
        }
    }

    /// Waits (bounded) for the persona to finish thinking/speaking so a
    /// capture window never cuts its reply off.
    private func waitUntilPipelineIdle() async {
        for _ in 0..<45 {
            let status = RealtimeChatState.shared.status
            if status != .thinking && status != .speaking { return }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled || !isSessionActive { return }
        }
    }

    // MARK: - Track handling

    private func handleSessionMatch(_ song: RecognizedSong) {
        let key = Self.trackKey(title: song.title, artist: song.artist)
        guard key != lastTrackKey else { return }  // same track still playing
        lastTrackKey = key
        presentMatch(song, emotion: "happy")

        // One comment per track change, rate-limited.
        guard Date().timeIntervalSince(lastCommentAt) >= Self.sessionCommentCooldown else { return }
        let event = Self.sessionCommentEvent(for: song)

        let settings = OpenAISettings.shared
        if settings.isLocalLLMEnabled {
            // Never barge in on an in-flight generation or TTS playback.
            let status = RealtimeChatState.shared.status
            guard status == .ready || status == .listening else { return }
            LocalLLMManager.shared.handleUserInput(event, logToTimeline: false)
        } else if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.sendInteractionEvent(event)
        } else {
            return
        }
        lastCommentAt = Date()
    }

    // MARK: - Auto-stop observers

    private func installSessionObservers() {
        let background = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopSession(reason: "background") }
        }
        // Only real device changes (headphones in/out) end the session — our
        // own capture windows churn the route on every cycle.
        let route = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                reason == .oldDeviceUnavailable || reason == .newDeviceAvailable
            else { return }
            Task { @MainActor in self?.stopSession(reason: "audio route change") }
        }
        sessionObservers = [background, route]
    }

    private func removeSessionObservers() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
    }

    // MARK: - Pure helpers (unit-tested)

    /// Punctuation/case-insensitive track identity ("J.V.K.E" == "JVKE"),
    /// so catalog spelling variants of the same track don't re-trigger a
    /// comment. Strips separators entirely — unlike the small-talk dedupe
    /// normalize, which keeps word boundaries.
    nonisolated static func trackKey(title: String, artist: String) -> String {
        "\(title) \(artist)".lowercased().filter { $0.isLetter || $0.isNumber }
    }

    nonisolated static func sessionCommentEvent(for song: RecognizedSong) -> String {
        "*You're listening to music together with the user and a new track just came on: "
            + "\"\(song.title)\" by \(song.artist). React to it in ONE short, playful "
            + "in-character sentence, in your usual speaking style and language.*"
    }

    nonisolated static func hasExceededDuration(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= sessionMaxDuration
    }

    /// Battery guard: level is -1 when monitoring is unavailable (simulator) —
    /// never a reason to stop.
    nonisolated static func isBatteryCritical(level: Float, state: UIDevice.BatteryState) -> Bool {
        guard level >= 0 else { return false }
        return level < sessionBatteryFloor && state == .unplugged
    }
}
