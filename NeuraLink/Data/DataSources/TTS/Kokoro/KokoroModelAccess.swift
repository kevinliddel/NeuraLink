//
//  KokoroModelAccess.swift
//  NeuraLink
//
//  Resolves on-disk paths for Kokoro model and resource files.
//
//  Priority: App Bundle -> Development Resource Path -> Application Support.
//

import Foundation

enum KokoroModelAccess {

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

    static var kokoroModel: URL { resolve(name: "kokoro", ext: "onnx") }
    static var voicesBin: URL { resolve(name: "voices", ext: "bin") }
    static var vocabTxt: URL { resolve(name: "vocab", ext: "txt") }
    static var cmuDict: URL { resolve(name: "cmu", ext: "txt") }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: kokoroModel.path)
            && FileManager.default.fileExists(atPath: voicesBin.path)
            && FileManager.default.fileExists(atPath: vocabTxt.path)
            && FileManager.default.fileExists(atPath: cmuDict.path)
    }

    /// Bundle -> dev source folder -> Application Support.
    private static func resolve(name: String, ext: String) -> URL {
        let fm = FileManager.default
        let filename = "\(name).\(ext)"

        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundled
        }

        let devPath = URL(fileURLWithPath: "/Users/mac/Dedicatus/NeuraLink/NeuraLink/Dependencies/Kokoro/Resources/\(filename)")
        if fm.fileExists(atPath: devPath.path) {
            return devPath
        }

        return baseDirectory.appendingPathComponent(filename)
    }
}
