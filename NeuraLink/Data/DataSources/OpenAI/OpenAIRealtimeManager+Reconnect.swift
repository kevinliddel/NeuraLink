//
//  OpenAIRealtimeManager+Reconnect.swift
//  NeuraLink
//
//  Auto-reconnect for the Realtime WebRTC session
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B1). ICE / peer-connection failures,
//  a closed data channel and a dead channel on foreground return schedule a
//  reconnect with exponential backoff; once the new data channel opens the
//  last few turns are replayed as conversation items so the model keeps the
//  thread. A user-initiated disconnect cancels everything.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation
import UIKit
import WebRTC

/// Pure backoff schedule, testable without WebRTC.
nonisolated struct ReconnectPolicy: Sendable {
    static let delays: [TimeInterval] = [1, 2, 4, 8, 16]
    static let maxAttempts = 5
    /// ICE `.disconnected` often heals by itself; only act if it persists.
    static let iceDisconnectGrace: TimeInterval = 3
    /// How long to wait for the network to come back before an attempt.
    static let networkWaitTimeout: TimeInterval = 30
    /// Dialogue turns replayed after a reconnect.
    static let replayTurns = 6

    /// Delay before `attempt` (1-based); nil once attempts are exhausted.
    static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return delays[min(attempt, delays.count) - 1]
    }
}

extension OpenAIRealtimeManager {

    // MARK: - Data channel send

    /// Serialises `event` onto the data channel. Returns false (and logs)
    /// when the channel is not open, so callers never write into the void.
    @discardableResult
    func send(_ event: [String: Any]) -> Bool {
        guard let channel = remoteDataChannel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: event)
        else {
            nlLog("[AI]: dropped \(event["type"] as? String ?? "event") — data channel not open", level: .warning)
            return false
        }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    // MARK: - Failure detection

    func handleICEStateChange(_ newState: RTCIceConnectionState) {
        switch newState {
        case .failed:
            iceGraceTask?.cancel()
            scheduleReconnect(reason: "ice failed")
        case .disconnected:
            iceGraceTask?.cancel()
            iceGraceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ReconnectPolicy.iceDisconnectGrace))
                guard !Task.isCancelled, let self else { return }
                if self.peerConnection?.iceConnectionState == .disconnected {
                    self.scheduleReconnect(reason: "ice disconnected > \(Int(ReconnectPolicy.iceDisconnectGrace)) s")
                }
            }
        case .connected, .completed:
            iceGraceTask?.cancel()
        default:
            break
        }
    }

    func handlePeerStateChange(_ newState: RTCPeerConnectionState) {
        if newState == .failed { scheduleReconnect(reason: "peer connection failed") }
    }

    func handleDataChannelClosed() {
        guard !userRequestedDisconnect else { return }
        switch state.status {
        case .disconnected, .error, .connecting, .reconnecting: return
        default: scheduleReconnect(reason: "data channel closed")
        }
    }

    /// A session that died while backgrounded shows up as a non-open channel
    /// on foreground return.
    func installForegroundWatch() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.userRequestedDisconnect, self.settings.isEnabled else { return }
            switch self.state.status {
            case .ready, .listening, .thinking, .speaking:
                if self.remoteDataChannel?.readyState != .open {
                    self.scheduleReconnect(reason: "foreground with closed channel")
                }
            default:
                break
            }
        }
    }

    // MARK: - Scheduling

    func scheduleReconnect(reason: String) {
        guard settings.isEnabled, settings.hasValidKey, !userRequestedDisconnect else { return }
        guard reconnectTask == nil else { return }

        reconnectAttempt += 1
        guard let delay = ReconnectPolicy.delay(forAttempt: reconnectAttempt) else {
            nlLog("[AI Reconnect]: giving up after \(ReconnectPolicy.maxAttempts) attempts (\(reason))", level: .error)
            teardown()
            state.setError("Connection lost")
            reconnectAttempt = 0
            return
        }
        nlLog("[AI Reconnect]: \(reason) — attempt \(reconnectAttempt) in \(Int(delay)) s", level: .warning)
        isReconnecting = true
        teardown()
        state.status = .reconnecting(attempt: reconnectAttempt)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let online = await NetworkWaiter.waitForConnectivity(timeout: ReconnectPolicy.networkWaitTimeout)
            guard !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard online else {
                self.scheduleReconnect(reason: "no network")
                return
            }
            self.connect(isReconnect: true)
        }
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        iceGraceTask?.cancel()
        iceGraceTask = nil
        isReconnecting = false
        reconnectAttempt = 0
    }

    /// Called when the data channel opens. After a reconnect, replays the
    /// recent turns so the model keeps context, then clears the counters.
    func didOpenDataChannel() {
        guard isReconnecting else { return }
        isReconnecting = false
        reconnectAttempt = 0
        let items = Self.contextReplayItems(from: recentDialogue())
        for item in items { send(item) }
        nlLog("[AI Reconnect]: reconnected, replayed \(items.count) turns", level: .info)
    }

    private func recentDialogue() -> [ConversationMessage] {
        guard let id = ConversationStore.shared.activeConversationID else { return [] }
        return MemoryStore.shared.fetchRecentMessages(conversationID: id, limit: ReconnectPolicy.replayTurns * 2)
    }

    /// `conversation.item.create` events for the last spoken turns, oldest
    /// first. User turns are `input_text`; assistant turns are `text`.
    static func contextReplayItems(from messages: [ConversationMessage]) -> [[String: Any]] {
        messages
            .filter { $0.kind == "message" && ($0.isUser || $0.isAssistant) }
            .suffix(ReconnectPolicy.replayTurns)
            .map { message in
                [
                    "type": "conversation.item.create",
                    "item": [
                        "type": "message",
                        "role": message.isUser ? "user" : "assistant",
                        "content": [[
                            "type": message.isUser ? "input_text" : "text",
                            "text": message.content
                        ]]
                    ]
                ]
            }
    }
}
