//
//  MemoryExporter.swift
//  NeuraLink
//
//  User-owned export of everything the companion remembers
//  (docs/MEMORY_OWNERSHIP_PLAN.md §M2): facts, memories, observations,
//  mental models, journal and — optionally — conversations, as one JSON
//  file handed to the share sheet. Vectors are left out (large,
//  model-specific, meaningless outside the app).
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation

nonisolated struct MemoryExport: Codable, Sendable {
    static let formatVersion = 1

    struct Fact: Codable, Sendable { let subject, predicate, object: String; let createdAt: Date }
    struct Unit: Codable, Sendable {
        let id: Int64
        let type: String
        let bank: String
        let text: String
        let source: String
        let pinned: Bool
        let createdAt: Date
        let mentionedAt: Date
        let occurredStart: Date?
        let occurredEnd: Date?
        let proofCount: Int
        let sourceIDs: [Int64]
        let entities: [String]
    }
    struct Model: Codable, Sendable { let character, slug, question, content: String; let lastRefreshed: Date? }
    struct Journal: Codable, Sendable { let character, diary, opener: String; let createdAt: Date }
    struct Message: Codable, Sendable { let role, kind, content: String; let timestamp: Date }
    struct Conversation: Codable, Sendable { let title: String; let createdAt: Date; let messages: [Message] }

    var formatVersion = MemoryExport.formatVersion
    let exportedAt: Date
    let appVersion: String
    let characters: [String]
    let facts: [Fact]
    let memories: [Unit]
    let observations: [Unit]
    let mentalModels: [Model]
    let journal: [Journal]
    let conversations: [Conversation]?

    static func unit(_ u: MemoryUnit) -> Unit {
        Unit(
            id: u.id, type: u.factType.rawValue, bank: u.bank, text: u.text, source: u.source, pinned: u.pinned,
            createdAt: u.createdAt, mentionedAt: u.mentionedAt, occurredStart: u.occurredStart,
            occurredEnd: u.occurredEnd, proofCount: u.proofCount, sourceIDs: u.sourceIDs, entities: u.entities)
    }
}

final class MemoryExporter {
    static let shared = MemoryExporter()

    /// Per-conversation message cap unless `everything` is requested.
    static let messageCap = 500

    private let store: MemoryStore

    init(store: MemoryStore = .shared) {
        self.store = store
    }

    /// Gathers the export on the main actor (cheap indexed reads) and
    /// encodes/writes it off-main. Returns the temporary file URL.
    func export(includeConversations: Bool, everything: Bool = false) async throws -> URL {
        let export = build(includeConversations: includeConversations, everything: everything)
        return try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(export)
            let url = Self.fileURL(for: export.exportedAt)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    func build(includeConversations: Bool, everything: Bool = false) -> MemoryExport {
        let units = store.fetchUnits()
        let models = store.fetchMentalModels(character: RealtimeChatState.shared.selectedCharacterName)
        let characters = Set(units.map(\.bank).filter { !$0.isEmpty } + models.map(\.character).filter { !$0.isEmpty })
        var journal: [MemoryExport.Journal] = []
        for character in characters {
            journal += store.journalEntries(character: character, limit: 200).map {
                MemoryExport.Journal(character: $0.character, diary: $0.diary, opener: $0.opener, createdAt: $0.createdAt)
            }
        }
        var conversations: [MemoryExport.Conversation]?
        if includeConversations {
            conversations = store.fetchConversations().map { convo in
                var messages = store.fetchMessages(conversationID: convo.id)
                if !everything, messages.count > Self.messageCap { messages = Array(messages.suffix(Self.messageCap)) }
                return MemoryExport.Conversation(
                    title: convo.title, createdAt: convo.createdAt,
                    messages: messages.map { .init(role: $0.role, kind: $0.kind, content: $0.content, timestamp: $0.timestamp) })
            }
        }
        return MemoryExport(
            exportedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            characters: characters.sorted(),
            facts: store.fetchAllFacts().map { .init(subject: $0.subject, predicate: $0.predicate, object: $0.object, createdAt: $0.timestamp) },
            memories: units.filter { $0.factType != .observation }.map(MemoryExport.unit),
            observations: units.filter { $0.factType == .observation }.map(MemoryExport.unit),
            mentalModels: models.map { .init(character: $0.character, slug: $0.slug, question: $0.question, content: $0.content, lastRefreshed: $0.lastRefreshed) },
            journal: journal,
            conversations: conversations)
    }

    nonisolated static func fileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("NeuraLink-memory-\(formatter.string(from: date)).json")
    }
}
