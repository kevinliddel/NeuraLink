//
//  NeuraLinkApp.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import SwiftUI

@main
struct NeuraLinkApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    autoConnectAI()
                }
        }
    }

    private func autoConnectAI() {
        // Session-boundary observer (backgrounding → lastSeen stamp +
        // sessionDidEnd for the reflection pipeline). Idempotent.
        SessionLifecycle.shared.start()
        // Reflection pipeline: listens for boundaries, clears stale pending
        // notifications, runs launch catch-up. Idempotent.
        ReflectionManager.shared.start()

        // New session = new chat: every cold launch starts a fresh
        // conversation (created lazily on the first turn).
        ConversationStore.shared.startNewChat()

        // Clean up VRM import staging files orphaned by a kill mid-import.
        Task { await VRMImportService.shared.sweepStaging() }

        let settings = OpenAISettings.shared

        if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.connect()
        } else if settings.isLocalLLMEnabled && LocalModelDownloadManager.shared.isAvailable {
            LocalLLMManager.shared.startListening()
        }
    }
}
