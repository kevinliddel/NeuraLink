//
//  CloneSampleStore.swift
//  NeuraLink
//
//  Persists user-supplied reference audio samples for F5-TTS zero-shot
//  cloning. Each persona maps to one audio file under Application Support;
//  the engine queries `snapshot()` once at lazy-load to discover overrides
//  for the bundled defaults.
//
//  Phase 2a net-new per docs/local_llm_tts_plan.md §5.
//
//  Created by Dedicatus on 26/05/2026.
//

import Foundation

@MainActor
final class CloneSampleStore {

    static let shared = CloneSampleStore()

    private init() {
        try? FileManager.default.createDirectory(
            at: clonesDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Returns the URL of the stored clone for `persona`, or nil if none.
    func url(for persona: PersonaIdentifier) -> URL? {
        let url = clonesDirectory.appendingPathComponent(filename(for: persona))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies `source` into the store as the reference for `persona`.
    /// Overwrites any existing clone for that persona.
    func save(from source: URL, for persona: PersonaIdentifier) throws {
        let destination = clonesDirectory.appendingPathComponent(filename(for: persona))
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// Removes the stored clone for `persona`, if any.
    func remove(for persona: PersonaIdentifier) {
        let destination = clonesDirectory.appendingPathComponent(filename(for: persona))
        try? FileManager.default.removeItem(at: destination)
    }

    /// Map of every persona that currently has a stored clone, to its URL.
    /// Used by `F5TTSEngine` at lazy-load to override the bundled defaults.
    func snapshot() -> [PersonaIdentifier: URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: clonesDirectory,
            includingPropertiesForKeys: nil
        ) else { return [:] }

        var result: [PersonaIdentifier: URL] = [:]
        for entry in entries where entry.pathExtension == cloneExtension {
            let persona = entry.deletingPathExtension().lastPathComponent
            result[persona] = entry
        }
        return result
    }

    // MARK: - Layout

    private let cloneExtension = "wav"

    private func filename(for persona: PersonaIdentifier) -> String {
        "\(persona.lowercased()).\(cloneExtension)"
    }

    private var clonesDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.neura.link/clones", isDirectory: true)
    }
}
