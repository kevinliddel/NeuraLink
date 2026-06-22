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
        // New session = new chat: every cold launch starts a fresh
        // conversation (created lazily on the first turn).
        ConversationStore.shared.startNewChat()

        let settings = OpenAISettings.shared

        if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.connect()
        } else if settings.isLocalLLMEnabled && LocalModelDownloadManager.shared.isAvailable {
            LocalLLMManager.shared.startListening()
        }
    }
}
