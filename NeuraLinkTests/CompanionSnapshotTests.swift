//
//  CompanionSnapshotTests.swift
//  NeuraLinkTests
//
//  Widget snapshot model (docs/PRESENCE_BEYOND_APP_PLAN.md §P3).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Companion snapshot")
struct CompanionSnapshotTests {

    @Test("Snapshot round-trips through JSON with ISO dates")
    func roundTrip() throws {
        let original = CompanionSnapshot(
            character: "sonya", displayName: "Sonya", relationshipLabel: "Friends", relationshipScore: 0.62,
            opener: "Hey!", memoryLine: "You like tea.", lastChatAt: Date(timeIntervalSince1970: 1_800_000_000),
            thumbnailFile: "sonya.png", updatedAt: Date(timeIntervalSince1970: 1_800_000_100))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CompanionSnapshot.self, from: try encoder.encode(original))
        #expect(decoded == original)
        #expect(decoded.version == CompanionSnapshot.version)
    }

    @Test("Last-chat description reads naturally at every scale")
    func lastChat() {
        let now = Date()
        func snap(_ ago: TimeInterval?) -> CompanionSnapshot {
            CompanionSnapshot(
                character: "s", displayName: "S", relationshipLabel: "", relationshipScore: 0, opener: "",
                memoryLine: "", lastChatAt: ago.map { now.addingTimeInterval(-$0) }, thumbnailFile: nil, updatedAt: now)
        }
        #expect(snap(nil).lastChatDescription(now: now) == "No chats yet")
        #expect(snap(30).lastChatDescription(now: now) == "Just now")
        #expect(snap(600).lastChatDescription(now: now) == "10 min ago")
        #expect(snap(3 * 3_600).lastChatDescription(now: now) == "3 h ago")
        #expect(snap(30 * 3_600).lastChatDescription(now: now) == "Yesterday")
        #expect(snap(5 * 86_400).lastChatDescription(now: now) == "5 days ago")
    }

    @Test("Memory of the day rotates deterministically and skips long lines")
    @MainActor
    func memoryOfTheDay() {
        let short = MemoryUnit(
            id: 1, text: "User likes tea.", context: "", vector: [], vectorModel: "nl", bank: "", factType: .observation,
            source: "t", pinned: false, createdAt: Date(), mentionedAt: Date(), occurredStart: nil, occurredEnd: nil,
            proofCount: 1, sourceIDs: [], consolidatedAt: nil, tokens: "", entities: [])
        let long = MemoryUnit(
            id: 2, text: String(repeating: "x", count: 200), context: "", vector: [], vectorModel: "nl", bank: "",
            factType: .observation, source: "t", pinned: false, createdAt: Date(), mentionedAt: Date(),
            occurredStart: nil, occurredEnd: nil, proofCount: 1, sourceIDs: [], consolidatedAt: nil, tokens: "", entities: [])
        let day1 = Date(timeIntervalSince1970: 86_400 * 100)
        #expect(CompanionSnapshotWriter.memoryOfTheDay(from: [short, long], date: day1) == "User likes tea.")
        #expect(CompanionSnapshotWriter.memoryOfTheDay(from: [], date: day1).isEmpty)
    }
}
