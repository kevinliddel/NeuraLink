//
//  ReflectionTests.swift
//  NeuraLinkTests
//
//  Living Companion Phase 1: the reflection output parser, quiet-hours
//  notification clamp, transcript shaping, and the user-turn guard query.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Reflection Pipeline")
struct ReflectionTests {

    // MARK: - Parser

    @Test("Parses a well-formed three-line reflection")
    func parseWellFormed() {
        let raw = """
        DIARY: We talked about their trip to Kyoto. It made me happy.
        OPENER: Welcome back! Did you sort out the Kyoto hotel?
        NOTIFY: Still curious about your Kyoto plans — come tell me!
        """
        let reflection = ReflectionManager.parse(raw)
        #expect(reflection != nil)
        #expect(reflection?.diary == "We talked about their trip to Kyoto. It made me happy.")
        #expect(reflection?.opener == "Welcome back! Did you sort out the Kyoto hotel?")
        #expect(reflection?.notificationLine == "Still curious about your Kyoto plans — come tell me!")
    }

    @Test("Treats unlabeled leading text as the diary (local-prompt continuation)")
    func parseLocalContinuation() {
        // The local prompt ends with "DIARY:", so the model's output starts
        // with the diary content itself.
        let raw = """
        We laughed about the burnt toast this morning.
        OPENER: Made any better toast since we talked?
        NOTIFY: Toast report requested.
        """
        let reflection = ReflectionManager.parse(raw)
        #expect(reflection?.diary == "We laughed about the burnt toast this morning.")
        #expect(reflection?.opener == "Made any better toast since we talked?")
    }

    @Test("Joins wrapped label content and strips quotes")
    func parseMultilineAndQuotes() {
        let raw = """
        diary: "First line of the diary
        that wrapped onto a second line."
        opener: 'Hey again!'
        """
        let reflection = ReflectionManager.parse(raw)
        #expect(reflection?.diary == "First line of the diary that wrapped onto a second line.")
        #expect(reflection?.opener == "Hey again!")
        #expect(reflection?.notificationLine == "")
    }

    @Test("Rejects output with no usable diary")
    func parseRejectsEmpty() {
        #expect(ReflectionManager.parse("") == nil)
        #expect(ReflectionManager.parse("   \n  \n") == nil)
        #expect(ReflectionManager.parse("OPENER: hi\nNOTIFY: hey") == nil)
    }

    @Test("Caps runaway field lengths")
    func parseCapsLengths() {
        let longText = String(repeating: "a", count: 1_000)
        let reflection = ReflectionManager.parse("DIARY: \(longText)")
        #expect(reflection != nil)
        #expect(reflection!.diary.count <= 300)
    }

    // MARK: - Quiet-hours clamp

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: hour, minute: minute))!
    }

    @Test("Daytime delivery passes through unclamped")
    func clampDaytime() {
        // 10:00 + 6 h = 16:00 → unchanged.
        let fire = CompanionNotificationScheduler.clampedFireDate(
            now: date(hour: 10), delay: 6 * 3600, calendar: calendar)
        #expect(calendar.component(.hour, from: fire) == 16)
    }

    @Test("Late-night delivery moves to 09:30 next day")
    func clampLateNight() {
        // 17:00 + 6 h = 23:00 → next day 09:30.
        let fire = CompanionNotificationScheduler.clampedFireDate(
            now: date(hour: 17), delay: 6 * 3600, calendar: calendar)
        #expect(calendar.component(.hour, from: fire) == 9)
        #expect(calendar.component(.minute, from: fire) == 30)
        #expect(calendar.component(.day, from: fire) == 8)
    }

    @Test("Early-morning delivery moves to 09:30 same day")
    func clampEarlyMorning() {
        // 23:00 + 4 h = 03:00 next day → that day 09:30.
        let fire = CompanionNotificationScheduler.clampedFireDate(
            now: date(hour: 23), delay: 4 * 3600, calendar: calendar)
        #expect(calendar.component(.hour, from: fire) == 9)
        #expect(calendar.component(.minute, from: fire) == 30)
        #expect(calendar.component(.day, from: fire) == 8)
    }

    // MARK: - Debug delay override

    @Test("Debug launch argument shortens delivery and skips quiet hours")
    func debugDelayOverride() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: CompanionNotificationScheduler.debugDelayKey)
        defer { defaults.removeObject(forKey: CompanionNotificationScheduler.debugDelayKey) }

        let normal = CompanionNotificationScheduler.effectiveDelay(defaults: defaults)
        #expect(normal.delay == CompanionNotificationScheduler.defaultDelay)
        #expect(normal.clampQuietHours)

        defaults.set(60.0, forKey: CompanionNotificationScheduler.debugDelayKey)
        let debug = CompanionNotificationScheduler.effectiveDelay(defaults: defaults)
        #expect(debug.delay == 60)
        #expect(!debug.clampQuietHours)
    }

    // MARK: - Transcript shaping

    @Test("Transcript keeps the LAST turns and drops tool calls")
    func transcriptShaping() {
        var messages: [ConversationMessage] = []
        for i in 1...20 {
            messages.append(
                ConversationMessage(
                    id: Int64(i), conversationID: 1, role: i.isMultiple(of: 2) ? "assistant" : "user",
                    kind: "message", content: "turn \(i)", timestamp: Date()))
        }
        messages.append(
            ConversationMessage(
                id: 21, conversationID: 1, role: "tool",
                kind: "tool_call", content: "get_weather", timestamp: Date()))

        let transcript = ReflectionManager.transcript(from: messages)
        let lines = transcript.split(separator: "\n")
        #expect(lines.count == 16)
        #expect(lines.first == "User: turn 5")  // oldest kept
        #expect(lines.last == "You: turn 20")   // newest kept
        #expect(!transcript.contains("get_weather"))
    }

    // MARK: - Guard query

    @Test("userMessageCount counts only spoken user turns")
    func userTurnGuard() {
        let convID = MemoryStore.shared.insertConversation(title: "test_reflection_guard")
        #expect(convID > 0)
        defer { MemoryStore.shared.deleteConversation(id: convID) }

        MemoryStore.shared.insertMessage(conversationID: convID, role: "user", kind: "message", content: "hi")
        MemoryStore.shared.insertMessage(conversationID: convID, role: "assistant", kind: "message", content: "hello")
        MemoryStore.shared.insertMessage(conversationID: convID, role: "user", kind: "message", content: "how are you")
        MemoryStore.shared.insertMessage(conversationID: convID, role: "tool", kind: "tool_call", content: "x")

        #expect(MemoryStore.shared.userMessageCount(conversationID: convID) == 2)
        #expect(MemoryStore.shared.userMessageCount(conversationID: convID) < ReflectionManager.minUserTurns)
    }
}
