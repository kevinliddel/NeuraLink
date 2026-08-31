//
//  IdentifySongSkill.swift
//  NeuraLink
//
//  Listen through the microphone and identify the song currently playing.
//  The recognition result also drives the on-screen pop-up card with
//  Apple Music / YouTube links (SongRecognitionOverlay).
//
//  Created by Dedicatus on 31/08/2026.
//

import Foundation

@MainActor
final class IdentifySongSkill: Skill {
    static let toolName = AppFunctionTool.identifySong
    var pendingUIAction: (() -> Void)?

    func execute(arguments: [String: Any]) async -> String {
        await SongRecognitionManager.shared.recognizeForSkill()
    }
}
