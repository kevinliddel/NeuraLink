//
//  CompanionDepthTests.swift
//  NeuraLinkTests
//
//  Follow-up planning/wording and photo-memory helpers (docs/COMPANION_DEPTH_PLAN.md).
//

import Foundation
import Testing
import UIKit

@testable import NeuraLink

@MainActor
@Suite("Companion depth")
struct CompanionDepthTests {

    private func unit(_ id: Int64, start: Date, end: Date? = nil, user: Bool = true, type: MemoryFactType = .world) -> MemoryUnit {
        MemoryUnit(
            id: id, text: "fact \(id)", context: "", vector: [], vectorModel: "nl", bank: "", factType: type,
            source: "t", pinned: false, createdAt: start, mentionedAt: start, occurredStart: start, occurredEnd: end ?? start,
            proofCount: 1, sourceIDs: [], consolidatedAt: nil, tokens: "", entities: user ? ["user"] : ["Emily"])
    }

    @Test("Planner picks today / upcoming / afterwards, skips long spans, muted and fired")
    func planner() {
        let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!
        let day: TimeInterval = 86_400
        let units = [
            unit(1, start: now.addingTimeInterval(2 * day)),                    // upcoming
            unit(2, start: now.addingTimeInterval(-2 * day)),                   // afterwards
            unit(3, start: now.addingTimeInterval(-3_600)),                     // today
            unit(4, start: now.addingTimeInterval(10 * day)),                   // too far
            unit(5, start: now, end: now.addingTimeInterval(30 * day)),         // coarse span
            unit(6, start: now.addingTimeInterval(day), user: false),           // not about the user
            unit(7, start: now.addingTimeInterval(day)),                        // fired
            unit(8, start: now.addingTimeInterval(day))                         // muted
        ]
        let planned = FollowUpPlanner.plan(units: units, fired: ["7:upcoming"], muted: [8], now: now)
        #expect(planned.map(\.unitID) == [3, 1, 2])
        #expect(planned.map(\.kind) == [.today, .upcoming, .afterwards])

        let upcoming = planned[1]
        let fire = FollowUpPlanner.notificationDate(for: upcoming, now: now)
        #expect(fire != nil)
        #expect(MemoryTimelineModel.calendar.component(.hour, from: fire!) == 18)
        #expect(FollowUpPlanner.notificationDate(for: planned[0], now: now) == nil)
    }

    @Test("Fallback wording is deterministic and per kind")
    func wording() {
        let followUp = FollowUp(unitID: 1, kind: .afterwards, factText: "User ran the Berlin marathon.", date: Date())
        #expect(FollowUpWording.fallback(followUp) == "How did it go? User ran the Berlin marathon.")
        let prompt = FollowUpWording.prompt(followUp, character: "sonya")
        #expect(prompt.system.contains("Sonya"))
        #expect(prompt.user.contains("Berlin"))
    }

    @Test("Photo memory fact is an experience about the user with entities and EXIF date")
    func photoFact() {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let fact = PhotoMemoryService.fact(
            from: "A woman named Emily at Lake Como.", userWords: "my sister", takenAt: taken, character: "sonya")
        #expect(fact.factType == .experience)
        #expect(fact.text.hasPrefix("User showed Sonya a photo:"))
        #expect(fact.entities.contains("user"))
        #expect(fact.entities.contains("Emily"))
        #expect(fact.occurredStart == taken)
        #expect(PhotoMemoryService.parseExifDate("2026:09:20 14:03:00") != nil)
        #expect(PhotoMemoryService.parseExifDate("nope") == nil)
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 1_500)).image { _ in }
        let small = PhotoMemoryService.downscale(big, maxPixels: 1_024)
        #expect(max(small.size.width, small.size.height) <= 1_024)
    }

    @Test("Vision requests use the configured text model and the new token key")
    func visionBody() {
        let body = VisionAnalyzer.buildBody(base64Image: "AAAA", prompt: "describe")
        #expect(body["model"] as? String == OpenAISettings.shared.textModel)
        #expect(body["max_completion_tokens"] as? Int == 300)
        #expect(body["max_tokens"] == nil)
    }
}
