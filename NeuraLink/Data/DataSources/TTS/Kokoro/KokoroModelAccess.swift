//
//  KokoroModelAccess.swift
//  NeuraLink
//
//  Resolves on-disk paths for Kokoro model and resource files.
//
//  Big files (kokoro.onnx ~328 MB, voices.bin ~51 MB, cmu.txt ~3.5 MB)
//  are on-demand via `RemoteAssetCache` against the public
//  `Dedicatus/NeuraLink` HuggingFace dataset (§4.5 of
//  docs/app_size_reduction_plan.md). Tiny `vocab.txt` (~700 bytes)
//  stays bundled — pointless to make on-demand.
//
//  Priority for each async lookup:
//    1. Local dev source path — `/Dependencies/Kokoro/Resources/<file>`
//       — lets the iteration loop work without a download for the dev.
//    2. `RemoteAssetCache.url(for:)` — bundle → cache → HTTPS download.
//

import Foundation

enum KokoroModelAccess {

    /// Legacy App-Support subdirectory used before §4.5. Kept so a
    /// previously-saved file at this path is still discoverable for
    /// `isAvailable`; new downloads land under `<App Support>/hf-assets/`.
    static let subDir = "models/tts"

    static var baseDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("com.neura.link/\(subDir)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Tiny vocab file (~700 bytes) — stays bundled, sync resolve.
    static var vocabTxt: URL {
        if let bundled = Bundle.main.url(forResource: "vocab", withExtension: "txt") {
            return bundled
        }
        let dev = devPath(for: "vocab.txt")
        if FileManager.default.fileExists(atPath: dev.path) {
            return dev
        }
        return baseDirectory.appendingPathComponent("vocab.txt")
    }

    /// On-demand. Triggers an HF download on first run for users whose
    /// bundle no longer ships `kokoro.onnx`. Returns instantly when the
    /// file is bundled, on the dev source path, or already cached.
    static func kokoroModel() async throws -> URL {
        if let dev = devPathIfExists(for: "kokoro.onnx") { return dev }
        return try await RemoteAssetCache.shared.url(for: .kokoroModel)
    }

    /// On-demand. See `kokoroModel()` for resolution order.
    static func voicesBin() async throws -> URL {
        if let dev = devPathIfExists(for: "voices.bin") { return dev }
        return try await RemoteAssetCache.shared.url(for: .kokoroVoices)
    }

    /// On-demand. See `kokoroModel()` for resolution order.
    static func cmuDict() async throws -> URL {
        if let dev = devPathIfExists(for: "cmu.txt") { return dev }
        return try await RemoteAssetCache.shared.url(for: .kokoroCMU)
    }

    /// True when every required Kokoro asset is resolvable from local
    /// disk without a network round-trip. `TTSEngineSelector` consults
    /// this to decide whether to fall back to `SystemTTSEngine` while
    /// assets are still downloading on a fresh install.
    static var isAvailable: Bool {
        RemoteAssetRegistry.kokoroModel.isCachedLocally
            && RemoteAssetRegistry.kokoroVoices.isCachedLocally
            && RemoteAssetRegistry.kokoroCMU.isCachedLocally
            && vocabAvailable
    }

    // MARK: - Internals

    private static var vocabAvailable: Bool {
        if Bundle.main.url(forResource: "vocab", withExtension: "txt") != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: devPath(for: "vocab.txt").path)
    }

    private static func devPath(for filename: String) -> URL {
        URL(fileURLWithPath: "/Users/mac/Dedicatus/NeuraLink/NeuraLink/Dependencies/Kokoro/Resources/\(filename)")
    }

    private static func devPathIfExists(for filename: String) -> URL? {
        let url = devPath(for: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
