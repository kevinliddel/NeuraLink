//
//  MusicSkill.swift
//  NeuraLink
//
//  Search for and play music in Apple Music.
//
//  Created by Dedicatus on 10/05/2026.
//

import Foundation
import UIKit

@MainActor
final class MusicSkill: Skill {
    static let toolName = AppFunctionTool.playMusic
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        let query = arguments["query"] as? String ?? ""
        return openMusic(query: query)
    }

    private func openMusic(query: String) -> String {
        let encoded = query.urlEncoded
        let schemes: [String] = [
            "music://music.apple.com/search?term=\(encoded)",
            "https://music.apple.com/search?term=\(encoded)"
        ]
        for scheme in schemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                pendingUIAction = { UIApplication.shared.open(url) }
                return "An Apple Music search for \"\(query)\" is ready on my phone — tap it to open."
            }
        }
        if let url = URL(string: "music://"), UIApplication.shared.canOpenURL(url) {
            pendingUIAction = { UIApplication.shared.open(url) }
            return "Apple Music is ready on my phone — tap it, then search for \"\(query)\"."
        }
        return "Apple Music doesn't appear to be available on this device."
    }
}
