//
//  MemoryOwnershipTests.swift
//  NeuraLinkTests
//
//  Export, weekly recap and timeline (docs/MEMORY_OWNERSHIP_PLAN.md).
//

import Foundation
import Testing
import UIKit

@testable import NeuraLink

@MainActor
@Suite("Memory ownership", .serialized)
struct MemoryOwnershipTests {

    @Test("Export round-trips, omits vectors and honours the conversations toggle")
    func export() async throws {
        let store = MemoryStore.shared
        let unitID = store.insertUnit(text: "User keeps an export marker Zyqxexp.", vector: [0.3, 0.4], factType: .world, source: "test")
        let convoID = store.insertConversation(title: "Export fixture Zyqxexp")
        store.insertMessage(conversationID: convoID, role: "user", kind: "message", content: "hello Zyqxexp")
        defer {
            store.deleteUnit(id: unitID)
            store.deleteConversation(id: convoID)
        }

        let exporter = MemoryExporter()
        let url = try await exporter.export(includeConversations: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("\"vector\""))
        #expect(text.contains("Zyqxexp"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MemoryExport.self, from: data)
        #expect(decoded.formatVersion == MemoryExport.formatVersion)
        #expect(decoded.memories.contains { $0.id == unitID && $0.type == "world" })
        #expect(decoded.conversations?.contains { $0.title.contains("Zyqxexp") } == true)

        let without = exporter.build(includeConversations: false)
        #expect(without.conversations == nil)
        #expect(MemoryExporter.fileURL(for: Date()).lastPathComponent.hasPrefix("NeuraLink-memory-"))
    }

    @Test("Recap parts split the summary from the ASK line; weeks drive staleness")
    func recap() {
        let parts = MemoryMentalModels.recapParts("We talked about Kyoto.\nYou booked the train.\nASK: Did the trip happen?")
        #expect(parts.summary == "We talked about Kyoto. You booked the train.")
        #expect(parts.ask == "Did the trip happen?")
        #expect(MemoryMentalModels.recapParts("").ask.isEmpty)

        let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!
        #expect(MemoryMentalModels.weekKey(for: now) == "2026-W39")
        func model(refreshed: Date?, stale: Bool, lastID: Int64) -> MentalModel {
            MentalModel(id: 1, character: "sonya", slug: MemoryMentalModels.weeklyRecapSlug, question: "",
                        content: "x", isStale: stale, lastRefreshed: refreshed, lastMemoryID: lastID)
        }
        #expect(MemoryMentalModels.isRecapDue(model(refreshed: nil, stale: false, lastID: 0), latestMemoryID: 0, now: now))
        #expect(MemoryMentalModels.isRecapDue(model(refreshed: now.addingTimeInterval(-8 * 86_400), stale: false, lastID: 5), latestMemoryID: 5, now: now))
        #expect(!MemoryMentalModels.isRecapDue(model(refreshed: now.addingTimeInterval(-3_600), stale: false, lastID: 5), latestMemoryID: 9, now: now))
        #expect(MemoryMentalModels.isRecapDue(model(refreshed: now.addingTimeInterval(-3_600), stale: true, lastID: 5), latestMemoryID: 9, now: now))
        #expect(MemoryMentalModels.recapPromptLine("Short.\nASK: q") == "Short.")
    }

    @Test("Timeline buckets months across a year boundary and finds 'on this day'")
    func timeline() {
        let now = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
        let months = MemoryTimelineModel.recentMonths(count: 3, now: now)
        #expect(months.map(\.month) == [11, 12, 1])
        #expect(months.first?.year == 2025)

        func unit(_ id: Int64, occurred: String) -> MemoryUnit {
            let date = ISO8601DateFormatter().date(from: occurred)!
            return MemoryUnit(
                id: id, text: "u\(id)", context: "", vector: [], vectorModel: "nl", bank: "", factType: .world,
                source: "t", pinned: false, createdAt: date, mentionedAt: date, occurredStart: date, occurredEnd: date,
                proofCount: 1, sourceIDs: [], consolidatedAt: nil, tokens: "", entities: [])
        }
        let units = [unit(1, occurred: "2025-12-31T10:00:00Z"), unit(2, occurred: "2026-01-02T10:00:00Z"),
                     unit(3, occurred: "2025-01-15T10:00:00Z"), unit(4, occurred: "2026-01-15T09:00:00Z")]
        let counts = MemoryTimelineModel.countsByMonth(units, months: months)
        #expect(counts[months[1]] == 1)
        #expect(counts[months[2]] == 2)
        let days = MemoryTimelineModel.daysInMonth(units, month: months[2])
        #expect(days.count == 2)
        #expect(days.first?.units.first?.id == 4)
        #expect(MemoryTimelineModel.onThisDay(units, now: now).map(\.id) == [3])
    }

    @Test("Date-range store query returns dated units in range and undated only when asked")
    func rangeQuery() {
        let store = MemoryStore.shared
        let now = Date()
        let dated = store.insertUnit(
            text: "User ran the Zyqxrange 10k.", vector: [0.1], factType: .world, source: "test",
            occurredStart: now.addingTimeInterval(-2 * 86_400), occurredEnd: now.addingTimeInterval(-2 * 86_400))
        let undated = store.insertUnit(text: "User likes Zyqxrange soup.", vector: [0.1], factType: .world, source: "test")
        defer { [dated, undated].forEach { store.deleteUnit(id: $0) } }
        let start = now.addingTimeInterval(-7 * 86_400)
        let strict = store.fetchUnits(occurringBetween: start, and: now, includeUndated: false).map(\.id)
        #expect(strict.contains(dated))
        #expect(!strict.contains(undated))
        let loose = store.fetchUnits(occurringBetween: start, and: now, includeUndated: true).map(\.id)
        #expect(loose.contains(undated))
        #expect(store.countDatedUnits() >= 1)
    }
}

@Suite("Photoshoot capture")
struct PhotoshootCaptureTests {

    @Test("BGRA bytes convert to an image of the right size; bad input is rejected")
    func convert() throws {
        let width = 4, height = 3
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            bytes[pixel * 4] = 255      // B
            bytes[pixel * 4 + 3] = 255  // A
        }
        let image = try #require(FrameImageConverter.image(bgraBytes: bytes, width: width, height: height, scale: 2))
        #expect(image.size == CGSize(width: 2, height: 1.5))
        #expect(image.scale == 2)
        #expect(FrameImageConverter.image(bgraBytes: [0, 0, 0], width: 4, height: 3) == nil)
        #expect(FrameImageConverter.image(bgraBytes: bytes, width: 0, height: 3) == nil)
    }
}
