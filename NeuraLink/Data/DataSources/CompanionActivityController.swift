//
//  CompanionActivityController.swift
//  NeuraLink
//
//  Starts, updates and ends the session Live Activity
//  (docs/PRESENCE_BEYOND_APP_PLAN.md §P2). Driven by `RealtimeChatState`
//  changes; only runs while "Keep talking in background" is on, because
//  that is the only case where the session exists while the app is hidden.
//  Updates are debounced to respect the activity budget.
//
//  Created by Dedicatus on 27/09/2026.
//

import ActivityKit
import Foundation

final class CompanionActivityController: @unchecked Sendable {
    static let shared = CompanionActivityController()

    static let updateDebounce: Duration = .milliseconds(500)
    static let lastLineLimit = 80

    private var activity: Activity<CompanionActivityAttributes>?
    private var pendingUpdate: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var lastState: CompanionActivityAttributes.ContentState?

    private init() {}

    // MARK: - Wiring

    /// Observes status + transcript changes. Idempotent; call at launch.
    @MainActor
    func start() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            var previous: AIConnectionStatus?
            var previousLine = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let state = RealtimeChatState.shared
                let line = state.status == .ready || state.status == .listening ? state.aiTranscript : previousLine
                if state.status != previous || line != previousLine {
                    previous = state.status
                    previousLine = line
                    self.handle(status: state.status, lastLine: line)
                }
            }
        }
    }

    /// Maps engine status to the activity: start on a live status (when
    /// allowed), update on phase changes, end on disconnect / error.
    @MainActor
    func handle(status: AIConnectionStatus, lastLine: String) {
        guard let phase = Self.phase(for: status) else {
            end()
            return
        }
        let state = CompanionActivityAttributes.ContentState(
            phase: phase, lastLine: Self.trim(lastLine))
        if activity == nil {
            guard PresenceSettings.shared.keepTalkingInBackground,
                  ActivityAuthorizationInfo().areActivitiesEnabled
            else { return }
            startActivity(with: state)
        } else {
            scheduleUpdate(state)
        }
    }

    static func phase(for status: AIConnectionStatus) -> CompanionActivityAttributes.Phase? {
        switch status {
        case .ready, .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .reconnecting: return .reconnecting
        default: return nil
        }
    }

    static func trim(_ line: String) -> String {
        let flat = line.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= lastLineLimit ? flat : String(flat.prefix(lastLineLimit - 1)) + "…"
    }

    // MARK: - Activity lifecycle

    @MainActor
    private func startActivity(with state: CompanionActivityAttributes.ContentState) {
        let character = RealtimeChatState.shared.selectedCharacterName
        guard !character.isEmpty else { return }
        var thumbnail: String?
        if let png = CompanionNotificationScheduler.characterThumbnailData(for: character) {
            thumbnail = CompanionSnapshotStore.saveThumbnail(png, for: character)
        }
        let attributes = CompanionActivityAttributes(
            character: character.lowercased(),
            displayName: VRMModelRegistry.shared.entry(named: character)?.displayName ?? character.capitalized,
            thumbnailFile: thumbnail,
            startedAt: Date())
        do {
            activity = try Activity.request(
                attributes: attributes, content: .init(state: state, staleDate: nil), pushType: nil)
            lastState = state
            nlLog("[LiveActivity] started for \(character)", level: .info)
        } catch {
            nlLog("[LiveActivity] start failed: \(error)", level: .warning)
        }
    }

    @MainActor
    private func scheduleUpdate(_ state: CompanionActivityAttributes.ContentState) {
        guard state != lastState else { return }
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: Self.updateDebounce)
            guard !Task.isCancelled, let self, let activity = self.activity else { return }
            self.lastState = state
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    @MainActor
    func end() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            nlLog("[LiveActivity] ended", level: .info)
        }
    }
}
