//
//  KeepsakeRoomTests.swift
//  NeuraLinkTests
//
//  A room that remembers — the pure rules: which object each keepsake
//  becomes, where it stands on the table, and what the persona is told.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import simd
import Testing
@testable import NeuraLink

struct KeepsakeRoomTests {

    private func milestone(_ kind: MilestoneKind, daysAgo: Double, note: String = "") -> CompanionMilestone {
        CompanionMilestone(
            kind: kind, character: "sonya", achievedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            celebratedAt: nil, note: note)
    }

    @Test func daysTogetherMakeOnePlantAtTheFurthestStage() {
        let objects = KeepsakeRoomRules.objects(from: [
            milestone(.sevenDays, daysAgo: 20), milestone(.thirtyDays, daysAgo: 2)
        ])
        #expect(objects.count == 1)
        #expect(objects.first?.kind == .plant)
        #expect(objects.first?.stage == 2)
        #expect(objects.first?.milestone == .thirtyDays)
    }

    @Test func objectsKeepTheirNotesAndComeInEarnedOrder() {
        let objects = KeepsakeRoomRules.objects(from: [
            milestone(.firstConversation, daysAgo: 1),
            milestone(.firstSharedSong, daysAgo: 5, note: "Blue Train — John Coltrane"),
            milestone(.firstDiary, daysAgo: 3, note: "journal-7.jpg"),
            milestone(.firstPhoto, daysAgo: 4), milestone(.firstGame, daysAgo: 2)
        ])
        #expect(objects.map(\.kind) == [.sleeve, .polaroid, .frame, .die, .card])
        #expect(objects[0].note == "Blue Train — John Coltrane")
        #expect(objects[2].note == "journal-7.jpg")
        #expect(objects.allSatisfy { $0.stage == 0 })
    }

    @Test func everyObjectHasItsOwnPlaceOnTheTable() {
        var seen: [SIMD3<Float>] = []
        for kind in RoomObjectKind.allCases {
            let slot = KeepsakeRoomRules.slot(for: kind)
            let reach = simd_length(SIMD2(slot.spot.position.x, slot.spot.position.z))
            #expect(reach < KeepsakeRoomRules.tableRadius - 0.04, "\(kind) hangs over the edge")
            #expect(slot.spot.position.y == 0)
            #expect(!seen.contains(where: { simd_distance($0, slot.spot.position) < 0.03 }), "\(kind) shares a spot")
            seen.append(slot.spot.position)
        }
    }

    @Test func placementLeansTheTopAwayFromTheViewer() {
        let table = RoomSpot(position: .zero, yaw: 0)
        let slot = RoomSlot(spot: RoomSpot(position: [0.05, 0, 0.02], yaw: 0), leanBack: 0.3)
        let placed = KeepsakeRoomRules.placement(of: slot, on: table)
        #expect(abs(placed.position.y - KeepsakeRoomRules.tableHeight) < 1e-5)
        #expect(abs(placed.position.x - 0.05) < 1e-5 && abs(placed.position.z - 0.02) < 1e-5)
        let top = placed.rotation.act(SIMD3<Float>(0, 1, 0))
        #expect(top.z < -0.25 && top.y > 0.9)
    }

    @Test func placementFollowsTheTablesTurn() {
        let table = RoomSpot(position: [1, -0.02, 2], yaw: .pi / 2)
        let slot = RoomSlot(spot: RoomSpot(position: [0, 0, 0.1], yaw: 0))
        let placed = KeepsakeRoomRules.placement(of: slot, on: table)
        // A quarter turn about Y carries +Z onto +X.
        #expect(abs(placed.position.x - 1.1) < 1e-5)
        #expect(abs(placed.position.z - 2) < 1e-5)
        #expect(abs(placed.position.y - (KeepsakeRoomRules.tableHeight - 0.02)) < 1e-5)
        let front = placed.rotation.act(SIMD3<Float>(0, 0, 1))
        #expect(abs(front.x - 1) < 1e-5)
    }

    @Test func promptLineNamesTheObjectsAndNothingWhenEmpty() {
        #expect(KeepsakeRoomRules.promptLine(for: []) == nil)
        let objects = KeepsakeRoomRules.objects(from: [
            milestone(.firstSharedSong, daysAgo: 1, note: KeepsakeRoomRules.songNote(title: "Blue Train", artist: "John Coltrane")),
            milestone(.firstDiary, daysAgo: 2), milestone(.hundredDays, daysAgo: 3)
        ])
        let line = KeepsakeRoomRules.promptLine(for: objects) ?? ""
        #expect(line.contains("\u{201C}Blue Train\u{201D} by John Coltrane"))
        let untitled = KeepsakeRoomRules.describe(RoomObject(kind: .sleeve, milestone: .firstSharedSong, achievedAt: Date(), note: "Solo"))
        #expect(untitled.contains("\u{201C}Solo\u{201D}, the first song") && !untitled.contains(" by "))
        #expect(line.contains("closed notebook"))
        #expect(line.contains("in flower"))
        #expect(line.contains("never list them"))
    }

    @Test func songNoteRoundTrips() {
        let note = KeepsakeRoomRules.songNote(title: " Blue Train ", artist: "John Coltrane")
        let parts = KeepsakeRoomRules.songParts(note)
        #expect(parts?.title == "Blue Train" && parts?.artist == "John Coltrane")
        // Dashes in a title or an artist survive the trip.
        let dashed = KeepsakeRoomRules.songParts(KeepsakeRoomRules.songNote(title: "Song — Remix", artist: "A — B"))
        #expect(dashed?.title == "Song — Remix" && dashed?.artist == "A — B")
        #expect(KeepsakeRoomRules.songNote(title: "", artist: "X").isEmpty)
        #expect(KeepsakeRoomRules.songParts("Solo")?.artist == "")
        #expect(KeepsakeRoomRules.songParts("  ") == nil)
    }
}
