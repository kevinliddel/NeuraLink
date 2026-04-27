//
//  NeuraLinkApp.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import SwiftUI

@main
struct NeuraLinkApp: App {
    init() {
        LocalLLMManager.shared.preload()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
