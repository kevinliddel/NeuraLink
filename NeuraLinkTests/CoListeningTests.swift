//
//  CoListeningTests.swift
//  NeuraLinkTests
//
//  Living Companion Phase 4a: the co-listening session's pure helpers —
//  track dedupe, auto-stop guards, comment builder, and the widened
//  identify_song tool schema.
//

import Foundation
import Testing
import UIKit

@testable import NeuraLink

@Suite("Co-Listening Session")
struct CoListeningTests {

    // MARK: - Track dedupe

    @Test("Track key ignores case and punctuation")
    func trackKeyDedupe() {
        let a = SongRecognitionManager.trackKey(title: "Golden Hour", artist: "JVKE")
        let b = SongRecognitionManager.trackKey(title: "golden hour!", artist: "J.V.K.E")
        #expect(a == b)

        let c = SongRecognitionManager.trackKey(title: "Golden Hour (Live)", artist: "JVKE")
        #expect(a != c)
    }

    // MARK: - Auto-stop guards

    @Test("Session ends exactly at the 30-minute cap")
    func durationCap() {
        let start = Date()
        #expect(!SongRecognitionManager.hasExceededDuration(
            startedAt: start, now: start.addingTimeInterval(29 * 60)))
        #expect(SongRecognitionManager.hasExceededDuration(
            startedAt: start, now: start.addingTimeInterval(30 * 60)))
    }

    @Test("Battery guard trips only when low AND unplugged")
    func batteryGuard() {
        #expect(SongRecognitionManager.isBatteryCritical(level: 0.15, state: .unplugged))
        #expect(!SongRecognitionManager.isBatteryCritical(level: 0.15, state: .charging))
        #expect(!SongRecognitionManager.isBatteryCritical(level: 0.5, state: .unplugged))
        // -1 = monitoring unavailable (simulator) — never a stop reason.
        #expect(!SongRecognitionManager.isBatteryCritical(level: -1, state: .unplugged))
    }

    // MARK: - Comment builder

    @Test("Session comment names the track and stays a single reaction")
    func commentEvent() {
        let song = RecognizedSong(
            title: "Golden Hour", artist: "JVKE", artworkURL: nil, appleMusicURL: nil)
        let event = SongRecognitionManager.sessionCommentEvent(for: song)
        #expect(event.contains("Golden Hour"))
        #expect(event.contains("JVKE"))
        #expect(event.contains("listening to music together"))
        #expect(event.contains("ONE short"))
        #expect(event.hasPrefix("*") && event.hasSuffix("*"))
    }

    // MARK: - Tool schema

    @Test("identify_song schema offers the session mode")
    func toolSchemaMode() {
        let tool = AppFunctionTool.all.first {
            ($0["name"] as? String) == AppFunctionTool.identifySong
        }
        let parameters = tool?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        let mode = properties?["mode"] as? [String: Any]
        let enums = mode?["enum"] as? [String]
        #expect(enums?.contains("session") == true)
        #expect(enums?.contains("once") == true)
        // mode stays optional — plain identification needs no arguments.
        let required = parameters?["required"] as? [String]
        #expect(required?.isEmpty == true)
    }
}
