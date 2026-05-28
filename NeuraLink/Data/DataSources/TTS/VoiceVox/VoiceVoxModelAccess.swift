//
//  VoiceVoxModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk paths for VOICEVOX resources.
//  One responsibility: path resolution for the Open JTalk dictionary and
//  the per-speaker `.vvm` model files.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

enum VoiceVoxModelAccess {

    private static let dicFolderName = "open_jtalk_dic_utf_8-1.11"
    private static let modelsFolderName = "voicevox_models"

    /// Path to the Open JTalk dictionary directory.
    /// Priority: Application Support (if customised) -> App Bundle.
    static func dictionaryPath() -> String? {
        let appSupportDic = appSupport.appendingPathComponent("voicevox/\(dicFolderName)")
        if FileManager.default.fileExists(atPath: appSupportDic.path) {
            return appSupportDic.path
        }

        if let bundlePath = Bundle.main.path(forResource: dicFolderName, ofType: nil) {
            return bundlePath
        }

        let bundleURL = Bundle.main.bundleURL
        let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var fallbackPath: String?

        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true, fileURL.lastPathComponent == dicFolderName {
                nlLog("[VoiceVox] Found blue-folder dictionary at: \(fileURL.path)", level: .info)
                return fileURL.path
            }

            if fileURL.lastPathComponent == "char.bin" {
                fallbackPath = fileURL.deletingLastPathComponent().path
            }
        }

        if let path = fallbackPath {
            nlLog("[VoiceVox] Found dictionary files at: \(path)", level: .info)
            return path
        }

        nlLog("[VoiceVox] ERROR: Could not find OpenJTalk dictionary in bundle.", level: .error)
        return nil
    }

    /// Full URL to a character-specific `.vvm` file.
    static func modelURL(forSpeakerID id: Int) -> URL? {
        let mapping = VoiceVoxSpeaker.map(id)
        let filenameID = mapping.filenameID
        let filename = "\(filenameID).vvm"

        let appSupportModel =
            appSupport
            .appendingPathComponent("voicevox/\(modelsFolderName)/\(filename)")
        if FileManager.default.fileExists(atPath: appSupportModel.path) {
            return appSupportModel
        }

        if let bundlePath = Bundle.main.path(forResource: "\(filenameID)", ofType: "vvm") {
            return URL(fileURLWithPath: bundlePath)
        }

        let bundleURL = Bundle.main.bundleURL
        let enumerator = FileManager.default.enumerator(
            at: bundleURL, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == filename {
                return fileURL
            }
        }

        nlLog("[VoiceVox] Could not find \(filename) in bundle.", level: .error)
        return nil
    }

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
