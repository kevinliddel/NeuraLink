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

    func isSpeakerReady(_ id: Int) -> Bool {
        isDictionaryAvailable && VoiceVoxModelAccess.isSpeakerAvailable(speakerID: id)
    }

    /// Placeholder for a direct `.vvm` download flow. (Speaker `.vvm` files are
    /// currently fetched on demand via `RemoteAssetCache` / the bundled voice
    /// download in `LocalModelDownloadManager`.)
    func downloadModel(forSpeakerID id: Int) async throws {
        nlLog("[VoiceVox] Stub download for speaker \(id)…", level: .info)
        try await Task.sleep(for: .seconds(2))
        downloadedSpeakerIDs.insert(id)
    }
}
