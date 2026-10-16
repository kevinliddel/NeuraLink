//
//  KeepsakeUnlockTests.swift
//  NeuraLinkTests
//
//  The "Keepsake collected" capsule controller (docs/LIVING_COMPANION.md):
//  one at a time, queued, and fed only by genuinely new keepsakes.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Keepsake unlock capsule")
struct KeepsakeUnlockTests {

    private let character = "test-unlock-\(UUID().uuidString.prefix(8))"

    private func keepsake(_ kind: MilestoneKind) -> CompanionMilestone {
        CompanionMilestone(kind: kind, character: character, achievedAt: Date(), celebratedAt: nil)
    }

    @Test("Keepsakes show one at a time and dismissal advances the queue")
    func queue() {
        let controller = KeepsakeUnlockController.shared
        controller.reset()
        defer { controller.reset() }

        controller.present(keepsake(.firstGame))
        controller.present(keepsake(.firstPhoto))
        #expect(controller.current?.kind == .firstGame)
        controller.dismiss()
        #expect(controller.current?.kind == .firstPhoto)
        controller.dismiss()
        #expect(controller.current == nil)
        controller.dismiss()
        #expect(controller.current == nil)
    }

    @Test("Recording a new keepsake presents it; recording it again does not")
    func trackerPresents() {
        let controller = KeepsakeUnlockController.shared
        controller.reset()
        defer {
            controller.reset()
            MemoryStore.shared.deleteMilestones(character: character)
        }

        CompanionMilestoneTracker.note(.firstSharedSong, character: character)
        #expect(controller.current?.kind == .firstSharedSong)
        #expect(controller.current?.character == character)
        controller.dismiss()
        CompanionMilestoneTracker.note(.firstSharedSong, character: character)
        #expect(controller.current == nil)
    }
}
