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
        if (arguments["mode"] as? String) == "session" {
            SongRecognitionManager.shared.startSession()
            return "Music session started! I'm listening along and will chime in when tracks change. "
                + "It runs for up to 30 minutes; the user can end it from the now-playing capsule."
        }
        return await SongRecognitionManager.shared.recognizeForSkill()
    }
}
