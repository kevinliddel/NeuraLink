//
//  VoiceVoxModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk paths for VOICEVOX resources.
//  One responsibility: path resolution for the Open JTalk dictionary and
//  the per-speaker `.vvm` model files.
//
//  Big files (per-speaker `.vvm` ~57 MB, JTalk dict ~102 MB) are
//  on-demand via `RemoteAssetCache` against the public
//  `Dedicatus/NeuraLink` HuggingFace dataset (§4.5 of
//  docs/app_size_reduction_plan.md). Bundle is consulted first so
//  builds with the assets still embedded behave identically.
//
//  Created by Dedicatus on 29/04/2026.
//  Made on-demand 29/05/2026.
//

import Foundation

enum VoiceVoxModelAccess {

    private static let dicFolderName = "open_jtalk_dic_utf_8-1.11"

    /// Returns a directory path that VOICEVOX's
    /// `voicevox_open_jtalk_rc_new` will accept. Resolution order:
    ///   1. Bundle lookup (covers the legacy bundled-dict shape).
    ///   2. `<App Support>/hf-assets/tts/voicevox/open_jtalk_dic/` — set
    ///      after a previous download completed.
    ///   3. Download every dict file from HF and return the directory
    ///      they were written into.
    static func dictionaryPath() async throws -> String? {
        if let path = bundleDictionaryPath() {
            return path
        }
        if let path = cachedDictionaryPath() {
            return path
        }
        // Fan out: download every dict file in parallel. The cache's
        // single-flight inFlight table handles dedup if another caller
        // is already fetching the same file.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for filename in RemoteAssetRegistry.jtalkDictFilenames {
                group.addTask {
                    _ = try await RemoteAssetCache.shared.url(for: .jtalkDictFile(filename))
                }
            }
            try await group.waitForAll()
        }
        return cachedDictionaryPath()
    }

    /// On-demand `.vvm` resolver. Downloads the speaker pack on first
    /// use; returns instantly when the file is bundled or cached.
    static func modelURL(forSpeakerID id: Int) async throws -> URL? {
        let mapping = VoiceVoxSpeaker.map(id)
        return try await RemoteAssetCache.shared.url(for: .voicevoxSpeaker(mapping.filenameID))
    }

    /// True when the dict directory is resolvable from local disk
    /// without a network round-trip. `PersonaSettingsView` consults
    /// this to show/hide the "Download Japanese voice pack" button.
    static var isDictionaryAvailable: Bool {
        bundleDictionaryPath() != nil || cachedDictionaryPath() != nil
    }

    /// True when the speaker pack for `id` is resolvable locally.
    static func isSpeakerAvailable(speakerID: Int) -> Bool {
        let mapping = VoiceVoxSpeaker.map(speakerID)
        return RemoteAssetRegistry.voicevoxSpeaker(mapping.filenameID).isCachedLocally
    }

    // MARK: - Internals

    /// Mirrors the original sync bundle/enumerator lookup that worked
    /// for the bundled dict at `<App>.app/open_jtalk_dic_utf_8-1.11/`.
    /// Preserved so builds that haven't stripped the dict yet keep
    /// working byte-for-byte.
    private static func bundleDictionaryPath() -> String? {
        if let bundlePath = Bundle.main.path(forResource: dicFolderName, ofType: nil) {
            return bundlePath
        }
        let bundleURL = Bundle.main.bundleURL
        let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey])
        var fallbackPath: String?
        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true,
                fileURL.lastPathComponent == dicFolderName {
                return fileURL.path
            }
            if fileURL.lastPathComponent == "char.bin" {
                fallbackPath = fileURL.deletingLastPathComponent().path
            }
        }
        return fallbackPath
    }

    /// Returns the directory holding the cached dict iff every required
    /// file is on disk. `sys.dic` alone isn't sufficient — VOICEVOX
    /// reads all of them on init.
    private static func cachedDictionaryPath() -> String? {
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        else { return nil }
        let dir = support
            .appendingPathComponent("hf-assets")
            .appendingPathComponent("tts/voicevox/open_jtalk_dic")
        for filename in RemoteAssetRegistry.jtalkDictFilenames {
            let path = dir.appendingPathComponent(filename).path
            if !FileManager.default.fileExists(atPath: path) {
                return nil
            }
        }
        return dir.path
    }
}
