//
//  SessionLifecycle.swift
//  NeuraLink
//
//  Marks chat-session boundaries — Living Companion Phase 0
//  (docs/LIVING_COMPANION_PLAN.md §0.1). The app previously had no lifecycle
//  seam at all: ConversationStore only knows `startNewChat()`, and nothing
//  observed backgrounding except the Metal render-loop pause.
//
//  A "session boundary" does NOT reset the active conversation — a brief app
//  switch must not fragment chat history. It only (a) stamps
//  InteractionClock.lastSeenAt and (b) posts `sessionDidEnd` with the active
//  conversation id, which Phase 1's ReflectionManager consumes.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation
import UIKit

final class SessionLifecycle: @unchecked Sendable {
    static let shared = SessionLifecycle()

    /// Posted on every session boundary that has an active conversation.
    /// userInfo: ["conversationID": Int64, "reason": String].
    static let sessionDidEnd = Notification.Name("NLSessionDidEnd")

    private var started = false

    private init() {}

    /// Installs the backgrounding observer. Called once from app launch;
    /// idempotent.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            InteractionClock.shared.markLastSeen()
            self?.sessionEnded(reason: "background")
        }
    }

    /// Declares a session boundary. Additional explicit callers: new-chat
    /// (ContentView.startNewChatSession) and character switch (VRMSceneView) —
    /// both invoke this BEFORE they reset/stop the conversation.
    /// No-ops while no conversation row exists (empty sessions don't reflect).
    func sessionEnded(reason: String) {
        guard let id = ConversationStore.shared.activeConversationID else { return }
        nlLog("[SessionLifecycle] Session boundary (\(reason)) — conversation \(id)", level: .info)
        NotificationCenter.default.post(
            name: Self.sessionDidEnd,
            object: nil,
            userInfo: ["conversationID": id, "reason": reason]
        )
    }
}
