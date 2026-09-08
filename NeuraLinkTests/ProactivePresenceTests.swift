//
//  ProactivePresenceTests.swift
//  NeuraLinkTests
//
//  Living Companion Phase 3: the proactive-engagement pure helpers —
//  backoff math, time-of-day buckets, event builders, dedupe normalization.
//  (The loop itself is a thin shell over these; timing is device territory.)
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Proactive Presence")
struct ProactivePresenceTests {

    // MARK: - Backoff

    @Test("Silence requirement backs off exponentially")
    func backoff() {
        #expect(ProactivePresenceManager.requiredSilence(base: 90, engagementsSoFar: 0) == 90)
        #expect(ProactivePresenceManager.requiredSilence(base: 90, engagementsSoFar: 1) == 270)
        #expect(ProactivePresenceManager.requiredSilence(base: 45, engagementsSoFar: 1) == 135)
    }

    // MARK: - Time of day

    @Test("Hours map to the expected buckets")
    func timeOfDay() {
        #expect(ProactivePresenceManager.timeOfDayDescriptor(hour: 6) == "early morning")
        #expect(ProactivePresenceManager.timeOfDayDescriptor(hour: 10) == "morning")
        #expect(ProactivePresenceManager.timeOfDayDescriptor(hour: 14) == "afternoon")
        #expect(ProactivePresenceManager.timeOfDayDescriptor(hour: 19) == "evening")
        #expect(ProactivePresenceManager.timeOfDayDescriptor(hour: 23) == "late night")
        #expect(ProactivePresenceManager.timeOfDayDescriptor(hour: 2) == "late night")
    }

    // MARK: - Greeting events

    @Test("Greeting delivers the saved opener verbatim")
    func greetingWithOpener() {
        let event = ProactivePresenceManager.greetingEvent(
            opener: "Did the rain ever stop?", hoursAway: 8, timeOfDay: "evening")
        #expect(event.contains("Did the rain ever stop?"))
        #expect(event.contains("8 hours"))
        #expect(event.contains("evening"))
        #expect(event.hasPrefix("*") && event.hasSuffix("*"))
    }

    @Test("Greeting without an opener falls back to a generic welcome")
    func greetingGeneric() {
        let event = ProactivePresenceManager.greetingEvent(
            opener: nil, hoursAway: 6, timeOfDay: "morning")
        #expect(event.contains("what they've been up to"))
        let emptyOpener = ProactivePresenceManager.greetingEvent(
            opener: "", hoursAway: 6, timeOfDay: "morning")
        #expect(emptyOpener.contains("what they've been up to"))
    }

    @Test("Long absences are phrased in days")
    func greetingDays() {
        let event = ProactivePresenceManager.greetingEvent(
            opener: nil, hoursAway: 75, timeOfDay: "afternoon")
        #expect(event.contains("3 days"))
        #expect(!event.contains("75 hours"))
    }

    // MARK: - Small-talk events

    @Test("Small talk carries time, stage, and the fact seed")
    func smallTalkSeeded() {
        let event = ProactivePresenceManager.smallTalkEvent(
            timeOfDay: "late night", stage: "Friends", factSeed: "User likes Sushi")
        #expect(event.contains("late night"))
        #expect(event.contains("Friends"))
        #expect(event.contains("User likes Sushi"))
        #expect(event.contains("don't ask whether they're still there"))
    }

    @Test("Small talk without a fact omits the reference clause")
    func smallTalkUnseeded() {
        let event = ProactivePresenceManager.smallTalkEvent(
            timeOfDay: "morning", stage: "New", factSeed: nil)
        #expect(!event.contains("you could reference"))
    }

    // MARK: - Dedupe

    @Test("Normalization collapses case and punctuation for dedupe")
    func dedupeNormalization() {
        let a = ProactivePresenceManager.normalize("It's late night — you're Friends!")
        let b = ProactivePresenceManager.normalize("its late night youre friends")
        #expect(a == b)

        let c = ProactivePresenceManager.normalize("It's early morning — you're Friends!")
        #expect(a != c)
    }
}
