//
//  CompanionSnapshotTests.swift
//  NeuraLinkTests
//
//  Widget snapshot model (docs/PRESENCE_BEYOND_APP.md).
//

import Foundation
import Metal
import Testing
import UIKit

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

    private func model(_ slug: String, _ content: String) -> MentalModel {
        MentalModel(id: 1, character: "sonya", slug: slug, question: "q", content: content,
                    isStale: false, lastRefreshed: nil, lastMemoryID: 0)
    }

    @Test("Widget memory line prefers the summary: Between you, then About you, then an observation")
    @MainActor
    func memoryLineSource() {
        let relationship = model(MemoryMentalModels.relationshipSlug,
                                 "You two bond over light novels. Kevin teases her about tea.")
        let profile = model(MemoryMentalModels.userProfileSlug, "Kevin is a developer in Paris.")
        let both = CompanionSnapshotWriter.memoryLine(models: [profile, relationship], observations: [])
        #expect(both.line == "You two bond over light novels.")
        #expect(both.title == "Between you")

        let profileOnly = CompanionSnapshotWriter.memoryLine(models: [profile, model(MemoryMentalModels.relationshipSlug, " ")],
                                                             observations: [])
        #expect(profileOnly.title == "About you")

        let none = CompanionSnapshotWriter.memoryLine(models: [], observations: [])
        #expect(none.line.isEmpty)
        #expect(none.title == nil)
    }

    @Test("Leading sentence is cut at a word boundary to fit the widget")
    func leadingSentence() {
        #expect(CompanionSnapshotWriter.leadingSentence(of: "One. Two.") == "One.")
        #expect(CompanionSnapshotWriter.leadingSentence(of: "   ") == nil)
        let long = String(repeating: "word ", count: 60)
        let cut = CompanionSnapshotWriter.leadingSentence(of: long) ?? ""
        #expect(cut.hasSuffix("…"))
        #expect(cut.count <= CompanionSnapshotWriter.memoryLineLimit + 1)
        #expect(!cut.contains("wor…"))
    }

    @Test("Snapshots from older builds (no memory title / stats) still decode")
    func decodesOlderSnapshot() throws {
        let json = """
        {"version":1,"character":"sonya","displayName":"Sonya","relationshipLabel":"Friends",
         "relationshipScore":0.5,"opener":"","memoryLine":"","updatedAt":"2026-09-30T10:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CompanionSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.memoryTitle == nil)
        #expect(snapshot.factCount == nil)
    }

    @Test("Live portrait renders the dressed model head and shoulders")
    @MainActor
    func livePortrait() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let url = try #require(Bundle.main.url(forResource: "Sonya", withExtension: "vrm"))
        let model = try await VRMModel.load(from: url, device: device)
        let renderer = try #require(VRMPartThumbnailRenderer(size: 256))
        let image = try #require(renderer.renderPortrait(of: model, recolorsFrom: nil))
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(model.hiddenPrimitives.isEmpty, "render must restore the model's hidden set")
    }
}
