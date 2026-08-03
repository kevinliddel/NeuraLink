//
//  VRMModelRegistry.swift
//  NeuraLink
//
//  The character catalogue: bundled `.vrm`/`.glb` models plus user-imported
//  characters from the `imported_characters` table. Extracted from
//  ContentView and converted from an immutable `enum` + `static let` to an
//  `@Observable` singleton so imports/deletions appear without an app
//  relaunch — views re-render off `all`, and `refresh()` rebuilds it.
//
//  **Search order:**
//  1. Known bundled names via `Bundle.main.url(forResource:withExtension:)`.
//  2. Anything inside a `Models/` folder reference, if one is present.
//  3. Imported characters (non-quarantined rows whose file is still on disk).
//
//  Entries are deduplicated by lowercased name; imported slugs are uniqued
//  against the bundled names at import time (VRMImportService.reservedSlugs).
//

import Foundation
import Observation

@Observable
@MainActor
final class VRMModelRegistry {
    static let shared = VRMModelRegistry()

    struct Entry: Hashable {
        /// Identity: the model filename stem — a bundled name ("Ekaterina")
        /// or an imported slug ("miko"). This is what becomes the
        /// PersonaIdentifier when the model loads.
        let name: String
        /// What the picker shows. Same as `name` for bundled characters; the
        /// user-chosen name for imports.
        let displayName: String
        let url: URL
        let isImported: Bool
    }

    private(set) var all: [Entry] = []

    private init() {
        refresh()
    }

    /// Rebuilds the catalogue. Call after an import or deletion.
    func refresh() {
        var seen = Set<String>()
        all = (Self.namedEntries() + Self.folderEntries() + Self.importedEntries())
            .filter { seen.insert($0.name.lowercased()).inserted }
    }

    /// Factory default: Ekaterina, else the first bundled model, else anything.
    var defaultModel: Entry? {
        all.first { $0.name.lowercased() == "ekaterina" }
            ?? all.first { !$0.isImported }
            ?? all.first
    }

    func entry(named name: String) -> Entry? {
        all.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Launch-time selection: the persisted choice if it still resolves
    /// (the file may have been deleted or quarantined since), else default.
    var initialSelection: Entry? {
        if let saved = UserSettings.shared.selectedCharacter,
           let entry = entry(named: saved) {
            return entry
        }
        return defaultModel
    }

    // MARK: - Sources

    private static func namedEntries() -> [Entry] {
        [
            ("Sonya", "vrm"), ("Ekaterina", "vrm"),
            ("Sonya", "glb"), ("Ekaterina", "glb")
        ]
        .compactMap { name, ext -> Entry? in
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                return nil
            }
            return Entry(name: name, displayName: name, url: url, isImported: false)
        }
    }

    private static func folderEntries() -> [Entry] {
        guard let dir = Bundle.main.url(forResource: "Models", withExtension: nil) else {
            return []
        }
        let urls =
            (try? FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return
            urls
            .filter { ["vrm", "glb"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                let stem = $0.deletingPathExtension().lastPathComponent
                return Entry(name: stem, displayName: stem, url: $0, isImported: false)
            }
    }

    /// Existence check only — the full size+hash re-verification runs when
    /// the model is actually loaded (VRMSceneView), where a failure
    /// quarantines the row and drops it from the next refresh.
    private static func importedEntries() -> [Entry] {
        ImportedCharacterStore.shared.all.compactMap { character in
            guard let url = character.fileURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Entry(
                name: character.slug,
                displayName: character.displayName,
                url: url,
                isImported: true)
        }
    }
}
