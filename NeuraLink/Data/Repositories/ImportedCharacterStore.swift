//
//  ImportedCharacterStore.swift
//  NeuraLink
//
//  Facade over the `imported_characters` table (MemoryStore+ImportedCharacters)
//  for user-imported VRM characters. Mirrors PersonaStore: `lastUpdated` is
//  bumped on every mutation so observing views (character picker, settings)
//  re-render; the rows themselves always come fresh from SQL.
//
//  Deleting here removes the character's SQL rows, its `character_ai` persona
//  rows, and its files. KV cache blobs are NOT touched: they are keyed by
//  config + prompt-hash, not by character (LocalLLMKVCache.path), so a deleted
//  character's blob simply never matches again — inert, regenerable dead disk
//  that the cache's own migration sweeps handle.
//

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class ImportedCharacterStore {
    static let shared = ImportedCharacterStore()

    /// Bumped on every mutation. Views observing this property re-render.
    var lastUpdated = Date()

    private init() {}

    // MARK: - Reads

    /// All non-quarantined imported characters, newest first.
    var all: [ImportedCharacter] {
        MemoryStore.shared.fetchImportedCharacters()
    }

    func character(slug: String) -> ImportedCharacter? {
        MemoryStore.shared.importedCharacter(slug: slug)
    }

    /// Duplicate detection by content hash (lowercase hex).
    func character(sha256: String) -> ImportedCharacter? {
        MemoryStore.shared.importedCharacter(sha256: sha256)
    }

    func isImported(slug: String) -> Bool {
        character(slug: slug) != nil
    }

    // MARK: - Mutations

    /// Registers a validated import. Returns nil when the insert is rejected
    /// (slug or sha256 already present) — the import pipeline checks both
    /// beforehand, so nil here means a race lost, not a user error.
    func add(_ draft: ImportedCharacterDraft) -> ImportedCharacter? {
        let row = MemoryStore.shared.insertImportedCharacter(draft)
        if row != nil { lastUpdated = Date() }
        return row
    }

    func rename(slug: String, to displayName: String) {
        MemoryStore.shared.updateImportedCharacterDisplayName(slug: slug, displayName: displayName)
        // Keep the OpenAI persona row's name in sync — nav titles and the
        // settings persona row read it (see plan D9).
        MemoryStore.shared.setPersonaName(
            character: slug, engine: MemoryStore.PersonaEngine.openai, name: displayName)
        lastUpdated = Date()
    }

    /// Marks a character whose file failed the integrity re-check. It stays
    /// in SQL (visible via includeQuarantined fetches) but leaves the registry.
    func quarantine(slug: String) {
        MemoryStore.shared.setImportedCharacterQuarantined(slug: slug, true)
        lastUpdated = Date()
    }

    /// Sets or replaces the character's card image; nil removes it (the
    /// picker card falls back to the letter placeholder). Raw picker bytes
    /// in, downscaled ≤512 px PNG on disk — always at `characters/<slug>.png`
    /// so the extension-swap thumbnail convention keeps working.
    func setThumbnail(slug: String, imageData: Data?) {
        guard let row = MemoryStore.shared.importedCharacter(slug: slug),
              let baseDir = try? ProtectedStorage.privateApplicationSupportURL()
        else { return }
        let path = "characters/\(row.slug).png"
        let dest = baseDir.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let imageData {
            guard let image = UIImage(data: imageData),
                  let png = VRMImportService.downscaledPNG(image, maxDimension: 512) else {
                nlLog("[ImportedCharacterStore] Unusable image data for '\(row.slug)' thumbnail", level: .warning)
                return
            }
            do {
                try png.write(to: dest, options: .atomic)
                try? ProtectedStorage.protect(dest)
                if row.thumbnailPath == nil {
                    MemoryStore.shared.updateImportedCharacterThumbnailPath(slug: slug, path: path)
                }
            } catch {
                nlLog("[ImportedCharacterStore] Thumbnail write failed for '\(row.slug)': \(error)", level: .warning)
                return
            }
        } else {
            try? FileManager.default.removeItem(at: dest)
            MemoryStore.shared.updateImportedCharacterThumbnailPath(slug: slug, path: nil)
        }
        lastUpdated = Date()
    }

    /// Re-render ping for mutations that bypassed this facade (the import
    /// service writes through MemoryStore from its own actor).
    func noteExternalMutation() {
        lastUpdated = Date()
    }

    /// Full removal: model file + thumbnail, SQL row, and `character_ai`
    /// persona rows. Chat history is untouched (conversations are not
    /// character-linked); KV caches are prompt-hash-keyed and self-cleaning
    /// (see header note).
    func delete(slug: String) {
        if let row = MemoryStore.shared.importedCharacter(slug: slug) {
            removeFile(at: row.fileURL)
            removeFile(at: row.thumbnailURL)
        }
        MemoryStore.shared.deleteImportedCharacter(slug: slug)
        MemoryStore.shared.deletePersonaRows(character: slug)
        lastUpdated = Date()
    }

    // MARK: - Nonisolated reads (registry refresh during scene loads)

    /// Thread-safe read for nonisolated contexts. SQL access is guarded by
    /// MemoryStore's NSLock (same pattern as PersonaVoiceStore's mirrors).
    nonisolated static func allFromSQL() -> [ImportedCharacter] {
        MemoryStore.shared.fetchImportedCharacters()
    }

    nonisolated static func fromSQL(slug: String) -> ImportedCharacter? {
        MemoryStore.shared.importedCharacter(slug: slug)
    }

    // MARK: - Cleanup helpers

    private func removeFile(at url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            nlLog("[ImportedCharacterStore] Failed to remove \(url.lastPathComponent): \(error)", level: .warning)
        }
    }
}
