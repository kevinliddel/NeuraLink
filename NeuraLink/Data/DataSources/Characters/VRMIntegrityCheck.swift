//
//  VRMIntegrityCheck.swift
//  NeuraLink
//
//  Load-time re-verification of an imported character's file against the
//  size + SHA-256 pin stored in `imported_characters`. The pin lives inside
//  the Data-Protected (optionally SQLCipher-encrypted) DB while the `.vrm`
//  sits as a plain file, so a filesystem-level attacker who swaps the model
//  can't fix up the hash without also defeating the DB layer.
//
//  Mirrors RemoteAssetCache.verify: size first (one stat), then a streaming
//  hash. On mismatch the row is quarantined — hidden from the registry, kept
//  in SQL so the user can see what happened and re-import — and the caller
//  falls back to the default model.
//

import Foundation

nonisolated enum VRMIntegrityCheck {

    /// True when the on-disk file still matches its import-time pin.
    /// Quarantines the row and returns false on any mismatch or read failure.
    static func verify(_ character: ImportedCharacter) -> Bool {
        guard let url = character.fileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            quarantine(character, reason: "file missing")
            return false
        }

        let size = RemoteAssetCache.fileSize(at: url)
        guard size == character.fileSize else {
            quarantine(character, reason: "size \(size) != pinned \(character.fileSize)")
            return false
        }

        guard let hash = try? RemoteAssetCache.sha256Hex(of: url) else {
            quarantine(character, reason: "unreadable for hashing")
            return false
        }
        guard hash == character.sha256 else {
            quarantine(character, reason: "checksum mismatch")
            return false
        }
        return true
    }

    private static func quarantine(_ character: ImportedCharacter, reason: String) {
        nlLog("[VRMIntegrityCheck] Quarantining '\(character.slug)': \(reason)", level: .error)
        MemoryStore.shared.setImportedCharacterQuarantined(slug: character.slug, true)
    }
}
