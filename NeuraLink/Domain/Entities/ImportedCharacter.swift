//
//  ImportedCharacter.swift
//  NeuraLink
//
//  Domain types for user-imported VRM characters. A row in the
//  `imported_characters` table (MemoryStore+ImportedCharacters.swift) owns the
//  file identity, integrity pin, and license metadata of one imported `.vrm`.
//  The character's prompt/voice/per-engine name live in `character_ai`, keyed
//  by `slug` — the stored filename stem, which is also the PersonaIdentifier
//  the rest of the app derives from the loaded model URL.
//

import Foundation

/// One user-imported VRM character.
///
/// `nonisolated`: consumed off the main actor by the registry refresh and the
/// scene-load integrity check (see the `RemoteAssetRegistry` precedent).
nonisolated struct ImportedCharacter: Identifiable, Hashable, Sendable {
    let id: Int64
    /// Lowercase `[a-z0-9_]` identifier. Equals the stored filename stem, so
    /// `VRMSceneView`'s filename-derived persona key and the `character_ai`
    /// key are the same string with no extra mapping.
    let slug: String
    var displayName: String
    /// Path relative to `ProtectedStorage.privateApplicationSupportURL()`,
    /// e.g. `characters/miko.vrm`. Relative because the app container UUID
    /// changes across reinstalls.
    let filePath: String
    /// Byte size of the stored file, checked before the hash on every load.
    let fileSize: Int64
    /// Lowercase-hex SHA-256 of the stored file, re-verified before every load.
    let sha256: String
    let thumbnailPath: String?
    /// Filename as picked in the Files app, for display/debugging only.
    let sourceFilename: String?
    /// "0.x" | "1.0"
    let vrmSpec: String?
    let metaName: String?
    let metaAuthors: String?
    let metaLicenseURL: String?
    let metaAvatarPermission: String?
    let metaCommercialUsage: String?
    /// Set when the on-disk file failed the size/hash re-check. Quarantined
    /// rows are hidden from the registry but kept so the user can see what
    /// happened and re-import.
    var quarantined: Bool
    let createdAt: Date
    var updatedAt: Date

    /// Absolute URL of the stored `.vrm`; nil if the protected directory is
    /// unavailable (the app then behaves as if the character doesn't exist).
    var fileURL: URL? {
        (try? ProtectedStorage.privateApplicationSupportURL())?
            .appendingPathComponent(filePath)
    }

    var thumbnailURL: URL? {
        guard let thumbnailPath else { return nil }
        return (try? ProtectedStorage.privateApplicationSupportURL())?
            .appendingPathComponent(thumbnailPath)
    }
}

/// Field bundle for inserting a new row — everything except the DB-assigned
/// id, timestamps, and quarantine flag. Built by the import pipeline after
/// validation succeeds.
nonisolated struct ImportedCharacterDraft: Sendable {
    let slug: String
    let displayName: String
    let filePath: String
    let fileSize: Int64
    let sha256: String
    var thumbnailPath: String?
    var sourceFilename: String?
    var vrmSpec: String?
    var metaName: String?
    var metaAuthors: String?
    var metaLicenseURL: String?
    var metaAvatarPermission: String?
    var metaCommercialUsage: String?
}
