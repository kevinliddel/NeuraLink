//
//  TTSModelAccess.swift
//  NeuraLink
//
//  Created by Antigravity on 29/04/2026.
//

import Foundation

/// Manages resolution of paths for TTS models.
/// Priority: App Bundle → Development source folder → Application Support
struct TTSModelAccess {
    static let subDir = "models/tts"

    static var baseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("com.neura.link/\(subDir)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var ditModel: URL {
        resolve(name: "model", ext: "safetensors")
    }

    static var vocabConfig: URL {
        resolve(name: "vocab", ext: "txt")
    }

    static var vocoderModel: URL {
        resolve(name: "vocos", ext: "safetensors")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: ditModel.path) &&
        FileManager.default.fileExists(atPath: vocabConfig.path) &&
        FileManager.default.fileExists(atPath: vocoderModel.path)
    }

    // Resolve a model file: bundle → dev source folder → Application Support
    private static func resolve(name: String, ext: String) -> URL {
        let fm = FileManager.default
        let filename = "\(name).\(ext)"

        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundled
        }

        // Dev: files live inside the Xcode source folder (NeuraLink/NeuraLink/)
        let devPath = URL(fileURLWithPath: "/Users/mac/Dedicatus/NeuraLink/NeuraLink/\(filename)")
        if fm.fileExists(atPath: devPath.path) {
            return devPath
        }

        return baseDirectory.appendingPathComponent(filename)
    }
}
