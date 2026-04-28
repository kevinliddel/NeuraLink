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
        let settings = OpenAISettings.shared
        
        if settings.isEnabled && settings.hasValidKey {
            OpenAIRealtimeManager.shared.connect()
        } else if settings.isLocalLLMEnabled && LocalModelDownloadManager.shared.isAvailable {
            LocalLLMManager.shared.startListening()
        }
    }
}
