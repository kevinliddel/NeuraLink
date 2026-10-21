//
//  VoiceVoxModelManager.swift
//  NeuraLink
//
//  Manages availability and lifecycle of VOICEVOX voice models, plus
//  dictionary verification and UI status reporting.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

@Observable
final class VoiceVoxModelManager {

    static let shared = VoiceVoxModelManager()

    private(set) var isDictionaryAvailable = false
    private(set) var downloadedSpeakerIDs: Set<Int> = []

    private init() {
        refreshStatus()
    }

    func refreshStatus() {
        isDictionaryAvailable = VoiceVoxModelAccess.isDictionaryAvailable

        var foundIDs = Set<Int>()
        for speaker in VoiceVoxSpeaker.allBuiltIn
        where VoiceVoxModelAccess.isSpeakerAvailable(speakerID: speaker.id) {
            foundIDs.insert(speaker.id)
        }
        downloadedSpeakerIDs = foundIDs

        nlLog(
            "[VoiceVox] Refreshed status. Dictionary: \(isDictionaryAvailable). Models: \(downloadedSpeakerIDs)",
            level: .info
        )
    }

}
