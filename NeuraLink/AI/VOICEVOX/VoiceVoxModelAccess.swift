//
//  VoiceVoxModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk paths for VOICEVOX resources.
//  One responsibility: path resolution for dictionary and .vvm models.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

enum VoiceVoxModelAccess {

    // MARK: - Constants

    private static let dicFolderName = "open_jtalk_dic_utf_8-1.11"
    private static let modelsFolderName = "voicevox_models"

    // MARK: - Path Resolution

    /// The path to the Open JTalk dictionary directory.
    /// Priority:
    /// 1. Application Support (if updated/customized)
    /// 2. App Bundle (standard bundle)
    static func dictionaryPath() -> String? {
        // 1. Check Application Support
        let appSupportDic = appSupport.appendingPathComponent("voicevox/\(dicFolderName)")
        if FileManager.default.fileExists(atPath: appSupportDic.path) {
            return appSupportDic.path
        }
        
        // 2. Check App Bundle (Exact Name)
        if let bundlePath = Bundle.main.path(forResource: dicFolderName, ofType: nil) {
            return bundlePath
        }

        // 3. Check App Bundle (Deep Search)
        let bundleURL = Bundle.main.bundleURL
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: [.isDirectoryKey])
        var fallbackPath: String?
        
        while let fileURL = enumerator?.nextObject() as? URL {
            // Priority 1: Find the actual directory (Folder Reference)
            // We check the attributes to ensure it's a directory
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true && fileURL.lastPathComponent == dicFolderName {
                print("[VoiceVox] SUCCESS: Found Blue Folder dictionary: \(fileURL.path)")
                return fileURL.path
            }
            
            // Priority 2: Find char.bin (Flattened Group - discouraged)
            if fileURL.lastPathComponent == "char.bin" {
                fallbackPath = fileURL.deletingLastPathComponent().path
            }
        }
        
        if let path = fallbackPath {
            print("[VoiceVox] Found dictionary files at: \(path)")
            return path
        }
        
        print("[VoiceVox] ERROR: Could not find OpenJTalk dictionary in bundle.")
        return nil
    }

    /// The full URL to a character-specific `.vvm` file.
    static func modelURL(forSpeakerID id: Int) -> URL? {
        let filename = "\(id).vvm"
        
        // 1. Check Application Support
        let appSupportModel = appSupport.appendingPathComponent("voicevox/\(modelsFolderName)/\(filename)")
        if FileManager.default.fileExists(atPath: appSupportModel.path) {
            return appSupportModel
        }
        
        // 2. Check App Bundle
        if let bundlePath = Bundle.main.path(forResource: "\(id)", ofType: "vvm") {
            return URL(fileURLWithPath: bundlePath)
        }
        
        // 3. Deep Search in Bundle
        let bundleURL = Bundle.main.bundleURL
        let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil)
        print("[VoiceVox] Scanning bundle for models...")
        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == "vvm" {
                print("[VoiceVox] Discovered model file: \(fileURL.lastPathComponent)")
            }
            if fileURL.lastPathComponent == filename {
                print("[VoiceVox] SUCCESS: Found model URL for ID \(id)")
                return fileURL
            }
        }

        print("[VoiceVox] FAILED: Could not find \(filename) in bundle.")
        return nil
    }

    // MARK: - Internals

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
