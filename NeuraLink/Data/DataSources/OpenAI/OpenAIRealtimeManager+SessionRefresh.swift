//
//  OpenAIRealtimeManager+SessionRefresh.swift
//  NeuraLink
//
//  Mid-session instruction refresh (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B2).
//  Instructions were assembled once at connect; now a persona edit, a
//  mental-model refresh, a new fact or a settings change posts
//  `.realtimeInstructionsDidChange`, and the manager re-sends
//  `session.update` (instructions + tools only, never voice) after a
//  debounce, deferred while a reply is in flight.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation
import WebRTC

extension Notification.Name {
    /// Something that feeds the Realtime system instructions changed.
    /// userInfo["reason"]: String.
    static let realtimeInstructionsDidChange = Notification.Name("NLRealtimeInstructionsDidChange")
}

/// Debounce + defer-while-busy state machine, testable without WebRTC.
nonisolated struct SessionRefreshScheduler: Sendable, Equatable {
    static let debounce: TimeInterval = 5

    private(set) var pendingSince: Date?
    private(set) var deferredWhileBusy = false

    /// Records a change. Returns the instant the refresh should fire.
    mutating func noteChange(at now: Date = Date()) -> Date {
        if pendingSince == nil { pendingSince = now }
        return now.addingTimeInterval(Self.debounce)
    }

    /// Called when the debounce elapses. Returns true when the refresh
    /// should be sent now; when `busy`, it is deferred to `responseFinished`.
    mutating func fire(busy: Bool) -> Bool {
        guard pendingSince != nil else { return false }
        if busy {
            deferredWhileBusy = true
            return false
        }
        pendingSince = nil
        deferredWhileBusy = false
        return true
    }

    /// Called on `response.done`. Returns true when a deferred refresh
    /// should be sent now.
    mutating func responseFinished() -> Bool {
        guard deferredWhileBusy, pendingSince != nil else { return false }
        pendingSince = nil
        deferredWhileBusy = false
        return true
    }

    mutating func reset() {
        pendingSince = nil
        deferredWhileBusy = false
    }
}

extension OpenAIRealtimeManager {

    /// Post from anywhere that changes an instruction input.
    static func postInstructionsChanged(reason: String) {
        NotificationCenter.default.post(
            name: .realtimeInstructionsDidChange, object: nil, userInfo: ["reason": reason])
    }

    func installInstructionRefreshObserver() {
        guard instructionsObserver == nil else { return }
        instructionsObserver = NotificationCenter.default.addObserver(
            forName: .realtimeInstructionsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?["reason"] as? String ?? "unknown"
            guard let self else { return }
            Task { @MainActor in self.requestInstructionRefresh(reason: reason) }
        }
    }

    func requestInstructionRefresh(reason: String) {
        guard remoteDataChannel?.readyState == .open else { return }
        let fireAt = refreshScheduler.noteChange()
        nlLog("[AI Refresh]: \(reason) — session.update in \(Int(SessionRefreshScheduler.debounce)) s", level: .info)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let delay = max(0, fireAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.flushInstructionRefresh()
        }
    }

    /// Sends the refresh unless a reply is in flight, in which case it is
    /// sent from `noteResponseFinished()`.
    func flushInstructionRefresh() {
        let busy = state.status == .speaking || state.status == .thinking
        guard refreshScheduler.fire(busy: busy) else {
            if busy { nlLog("[AI Refresh]: deferred until the current reply finishes", level: .info) }
            return
        }
        Task { await refreshSessionInstructions() }
    }

    /// Hook for `response.done`.
    func noteResponseFinished() {
        if refreshScheduler.responseFinished() {
            Task { await refreshSessionInstructions() }
        }
    }

    /// `session.update` carrying only instructions + tools. Voice is never
    /// included (GA rejects `cannot_update_voice` once audio is in flight).
    func refreshSessionInstructions() async {
        guard remoteDataChannel?.readyState == .open else { return }
        let instructions = await buildSessionInstructions()
        let update: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": instructions,
                "tools": AppFunctionTool.all,
                "tool_choice": "auto"
            ]
        ]
        if send(update) {
            nlLog("[AI Refresh]: sent session.update (\(instructions.count) chars)", level: .info)
        }
    }
}
