//
//  CompanionSceneCaptureTests.swift
//  NeuraLinkTests
//
//  Diary pictures (docs/LIVING_COMPANION.md): freshness, the journal copy,
//  the notification attachment's copy semantics, and the journal column.
//

import Foundation
import Testing
import UIKit

@testable import NeuraLink

@MainActor
@Suite("Companion scene capture")
struct CompanionSceneCaptureTests {

    private func samplePicture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    @Test("A capture is fresh for three hours and never from the future")
    func freshness() {
        let now = Date()
        #expect(CompanionSceneCapture.isFresh(modifiedAt: now.addingTimeInterval(-600), now: now, maxAge: 3_600))
        #expect(!CompanionSceneCapture.isFresh(modifiedAt: now.addingTimeInterval(-4_000), now: now, maxAge: 3_600))
        #expect(!CompanionSceneCapture.isFresh(modifiedAt: now.addingTimeInterval(60), now: now, maxAge: 3_600))
        #expect(!CompanionSceneCapture.isFresh(modifiedAt: nil, now: now, maxAge: 3_600))
    }

    @Test("The reflection adopts the latest capture as its own file, and removal cleans up")
    func journalCopy() throws {
        #expect(CompanionSceneCapture.saveLatest(samplePicture()))
        let latest = try #require(CompanionSceneCapture.latestCapture())
        #expect(FileManager.default.fileExists(atPath: latest.path))

        let name = try #require(CompanionSceneCapture.keepForJournal(entryID: -42))
        defer { CompanionSceneCapture.removeJournalFile(named: name) }
        #expect(name == "journal--42.jpg")
        let kept = try #require(CompanionSceneCapture.journalURL(named: name))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: latest.path))   // the latest is copied, not moved

        CompanionSceneCapture.removeJournalFile(named: name)
        #expect(CompanionSceneCapture.journalURL(named: name) == nil)
        #expect(CompanionSceneCapture.journalURL(named: nil) == nil)
    }

    @Test("The notification attachment is built from a copy, so the journal keeps its picture")
    func attachment() throws {
        #expect(CompanionSceneCapture.saveLatest(samplePicture()))
        let latest = try #require(CompanionSceneCapture.latestCapture())
        let attachment = try #require(CompanionSceneCapture.attachment(copying: latest))
        #expect(attachment.identifier == "companion-scene")
        #expect(FileManager.default.fileExists(atPath: latest.path))
    }

    @Test("The journal row carries its picture's file name")
    func journalColumn() {
        let character = "test-capture-\(UUID().uuidString.prefix(8))"
        let store = MemoryStore.shared
        defer { store.deleteJournal(character: character) }
        let id = store.insertJournalEntry(
            character: character, conversationID: 0, diary: "A quiet evening.", opener: "", notificationLine: "")
        #expect(id > 0)
        #expect(store.journalEntries(character: character).first?.snapshotFile == nil)
        store.setJournalSnapshot(id: id, file: "journal-\(id).jpg")
        #expect(store.journalEntries(character: character).first?.snapshotFile == "journal-\(id).jpg")
    }
}
