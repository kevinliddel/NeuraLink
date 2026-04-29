//
//  VoiceVoxModelManager.swift
//  NeuraLink
//
//  Manages the availability and lifecycle of VOICEVOX voice models.
//  Handles status reporting for the UI and dictionary verification.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

@Observable
final class VoiceVoxModelManager {

    // MARK: - Singleton

    static let shared = VoiceVoxModelManager()

    // MARK: - Properties

    private(set) var isDictionaryAvailable = false
    private(set) var downloadedSpeakerIDs: Set<Int> = []

    // MARK: - Init

    private init() {
        refreshStatus()
    }

    // MARK: - Actions

    func refreshStatus() {
        // 1. Check Dictionary
        isDictionaryAvailable = VoiceVoxModelAccess.dictionaryPath() != nil
        
        // 2. Scan for available .vvm files in the bundle
        var foundIDs = Set<Int>()
        for speaker in VoiceVoxSpeaker.allBuiltIn {
            if VoiceVoxModelAccess.modelURL(forSpeakerID: speaker.id) != nil {
                foundIDs.insert(speaker.id)
            }
        }
        self.downloadedSpeakerIDs = foundIDs
        
        print("[VoiceVox] Refreshed status. Dictionary: \(isDictionaryAvailable). Models: \(downloadedSpeakerIDs)")
    }

    /// Checks if a specific speaker is ready for synthesis.
    func isSpeakerReady(_ id: Int) -> Bool {
        return isDictionaryAvailable && VoiceVoxModelAccess.modelURL(forSpeakerID: id) != nil
    }

    // MARK: - Mock Download (Phase 1)
    
    /// Placeholder for the actual download logic to be implemented in Phase 2.
    func downloadModel(forSpeakerID id: Int) async throws {
        // TODO: Implement actual .vvm download from HF/Official repository.
        print("[VoiceVox] Starting download for speaker \(id)...")
        try await Task.sleep(for: .seconds(2))
        downloadedSpeakerIDs.insert(id)
    }
}
