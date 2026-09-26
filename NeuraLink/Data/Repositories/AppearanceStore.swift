//
//  AppearanceStore.swift
//  NeuraLink
//
//  Facade over the `character_appearance` table (MemoryStore+Appearance).
//  Mirrors ImportedCharacterStore: `lastUpdated` bumps on every mutation so
//  observing views re-render; specs always come fresh from SQL.
//
//  Keys are lowercased slugs — the model filename stem, the same identifier
//  the persona tables use — so bundled and imported characters both work,
//  and an imported character's delete cascades here (ImportedCharacterStore).
//

import Foundation
import Observation

@Observable
@MainActor
final class AppearanceStore {
    static let shared = AppearanceStore()

    /// Bumped on every mutation. Views observing this property re-render.
    var lastUpdated = Date()

    private init() {}

    // MARK: - Reads

    /// The saved look, or nil when the character has never been customized.
    func spec(for slug: String) -> AppearanceSpec? {
        Self.specFromSQL(slug: slug)
    }

    func hasCustomization(for slug: String) -> Bool {
        spec(for: slug).map { !$0.isEmpty } ?? false
    }

    // MARK: - Mutations

    /// Persists a normalized spec. An empty spec deletes the row so "reset
    /// everything" and "never customized" are indistinguishable on disk.
    func save(_ spec: AppearanceSpec, for slug: String) {
        let normalized = spec.normalized()
        if normalized.isEmpty {
            MemoryStore.shared.deleteAppearanceSpec(character: slug)
        } else if let json = try? normalized.jsonString() {
            MemoryStore.shared.setAppearanceSpecJSON(json, character: slug)
        } else {
            nlLog("[AppearanceStore] Could not encode spec for '\(slug)'", level: .warning)
            return
        }
        lastUpdated = Date()
    }

    func reset(for slug: String) {
        MemoryStore.shared.deleteAppearanceSpec(character: slug)
        lastUpdated = Date()
    }

    // MARK: - Nonisolated reads

    /// Thread-safe read for nonisolated contexts (scene load path). SQL
    /// access is guarded by MemoryStore's NSLock.
    nonisolated static func specFromSQL(slug: String) -> AppearanceSpec? {
        guard let json = MemoryStore.shared.appearanceSpecJSON(character: slug) else { return nil }
        return AppearanceSpec.fromJSON(json)
    }
}
