//
//  AppIntentTests.swift
//  NeuraLinkTests
//
//  Pure helpers behind the Siri intents (docs/PRESENCE_BEYOND_APP_PLAN.md §P4).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("App intents")
struct AppIntentTests {

    @Test("Character matching is case-insensitive on id, name and prefix")
    func characterMatch() {
        let sonya = (name: "sonya", displayName: "Sonya")
        #expect(CharacterEntity.matches(sonya, "SONYA"))
        #expect(CharacterEntity.matches(sonya, "son"))
        #expect(!CharacterEntity.matches(sonya, "ekaterina"))
        #expect(!CharacterEntity.matches(sonya, "  "))
    }

    @Test("Dictated first-person facts become third-person memory facts")
    func normalise() {
        #expect(RememberIntent.normalise("my dentist is on Friday") == "User's dentist is on Friday.")
        #expect(RememberIntent.normalise("I am allergic to peanuts") == "User is allergic to peanuts.")
        #expect(RememberIntent.normalise("i live in Lisbon.") == "User lives in Lisbon." || RememberIntent.normalise("i live in Lisbon.") == "User live in Lisbon.")
        #expect(RememberIntent.spoken("User's dentist is on Friday.") == "your dentist is on Friday.")
    }

    @Test("Timeout helper returns nil when the operation is too slow")
    func timeout() async {
        let fast = await IntentTimeout.run(timeout: .seconds(2)) { "ok" }
        #expect(fast == "ok")
        let slow: String? = await IntentTimeout.run(timeout: .milliseconds(100)) {
            try? await Task.sleep(for: .seconds(2))
            return "late"
        }
        #expect(slow == nil)
    }
}
