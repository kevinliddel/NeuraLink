//
//  F5TTSModelAccess.swift
//  NeuraLink
//
//  Resolves on-disk paths for F5-TTS model files. Lifted from feat/voice-cloning
//  at Phase 2a (formerly `TTSModelAccess`); renamed for symmetry with
//  `VoiceVoxModelAccess` and the planned `KokoroModelAccess`.
//
//  Priority: App Bundle → development source folder → Application Support.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

enum F5TTSModelAccess {

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

    static var ditModel: URL { resolve(name: "model", ext: "safetensors") }
    static var vocabConfig: URL { resolve(name: "vocab", ext: "txt") }
    static var vocoderModel: URL { resolve(name: "vocos", ext: "safetensors") }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: ditModel.path)
            && FileManager.default.fileExists(atPath: vocabConfig.path)
            && FileManager.default.fileExists(atPath: vocoderModel.path)
    }

    /// Bundle → dev source folder → Application Support.
    /// The dev source path is a development convenience only — Phase 5's
    /// `TTSAsset` work on `LocalModelDownloadManager` will replace it.
    private static func resolve(name: String, ext: String) -> URL {
        let fm = FileManager.default
        let filename = "\(name).\(ext)"

        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundled
        }

        let devPath = URL(fileURLWithPath: "/Users/mac/Dedicatus/NeuraLink/NeuraLink/\(filename)")
        if fm.fileExists(atPath: devPath.path) {
            return devPath
        }

        return baseDirectory.appendingPathComponent(filename)
    }
}
