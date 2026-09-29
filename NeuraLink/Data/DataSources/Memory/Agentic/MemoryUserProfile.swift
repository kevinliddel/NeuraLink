//
//  MemoryUserProfile.swift
//  NeuraLink
//
//  The three things the companion should never have to be told: who the
//  user is, when they were born, and how they'd like to be referred to.
//
//  They already live in Settings and reach the model through the system
//  prompt, but the agentic memory never held them, so recall and the
//  entity graph knew nothing about the person at the centre of every other
//  fact. These are written in as ordinary facts, phrased the same way the
//  extractor phrases everything else, so they rank, link and export like
//  any other memory.
//
//  Re-synced whenever the profile changes: the previous set is removed
//  first, so editing a birthday corrects the memory instead of leaving two
//  contradictory ones behind.
//

import Foundation

enum MemoryUserProfile {

    /// Marks the facts this file owns, so a re-sync can replace exactly
    /// those and nothing the user or the model wrote.
    static let source = "profile"

    /// How the user should be named in a fact. Their own name when they
    /// gave one, so memories read "Kevin's birthday is …" rather than the
    /// third-person "User's birthday is …" the extractor would otherwise
    /// produce.
    @MainActor
    static var subject: String {
        let name = UserSettings.shared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "The user" : name
    }

    /// Possessive form of `subject` ("Kevin's", "The user's").
    @MainActor
    static var possessive: String {
        let name = subject
        return name.hasSuffix("s") ? "\(name)'" : "\(name)'s"
    }

    /// Ground truth about the user for any prompt that would otherwise have
    /// to infer it from retrieved evidence — which is how "the user's name
    /// is unknown" kept turning up in a summary written for someone whose
    /// name is in Settings. Cached so prompts built off the main actor can
    /// read it; refreshed by `sync()`.
    nonisolated(unsafe) private(set) static var promptBlock = ""

    @MainActor
    private static func makePromptBlock() -> String {
        let settings = UserSettings.shared
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var known: [String] = []
        if !name.isEmpty { known.append("is called \(name)") }
        if settings.gender != "Prefer not to say", !settings.gender.isEmpty {
            known.append("is \(settings.gender)")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        known.append("was born on \(formatter.string(from: settings.birthday))")
        guard !known.isEmpty else { return "" }
        var block = "\nThe user \(known.joined(separator: ", ")). This is known — never call it unknown."
        if !name.isEmpty {
            block += " Refer to them by name (\"\(name)\", \"\(name)'s\"), not as \"the user\" or \"User\"."
        }
        return block
    }

    /// Writes the profile into memory, replacing whatever it wrote before.
    @MainActor
    static func sync() {
        promptBlock = makePromptBlock()
        let store = MemoryStore.shared
        for id in store.unitIDs(source: source) { store.deleteUnit(id: id) }

        let settings = UserSettings.shared
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var facts: [String] = []
        if !name.isEmpty {
            facts.append("\(name) is the user's name.")
        }
        if settings.gender != "Prefer not to say", !settings.gender.isEmpty {
            facts.append("\(possessive) gender is \(settings.gender).")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        facts.append("\(possessive) birthday is \(formatter.string(from: settings.birthday)).")

        for fact in facts {
            MemoryRetain.shared.retainFact(
                ExtractedFact(text: fact, factType: .world), source: source)
        }
    }
}
