//
//  SessionRefreshTests.swift
//  NeuraLinkTests
//
//  Debounce / defer state machine for the mid-session instruction refresh
//  (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B2).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Session instruction refresh")
struct SessionRefreshTests {

    @Test("Changes coalesce into one fire after the debounce")
    func debounce() {
        var scheduler = SessionRefreshScheduler()
        let t0 = Date()
        let first = scheduler.noteChange(at: t0)
        let second = scheduler.noteChange(at: t0.addingTimeInterval(2))
        #expect(first == t0.addingTimeInterval(SessionRefreshScheduler.debounce))
        #expect(second == t0.addingTimeInterval(2 + SessionRefreshScheduler.debounce))
        let fired = scheduler.fire(busy: false)
        #expect(fired)
        let firedAgain = scheduler.fire(busy: false)
        #expect(!firedAgain, "nothing pending after a fire")
    }

    @Test("A refresh during a reply waits for response.done")
    func deferWhileBusy() {
        var scheduler = SessionRefreshScheduler()
        _ = scheduler.noteChange()
        let firedWhileBusy = scheduler.fire(busy: true)
        #expect(!firedWhileBusy)
        #expect(scheduler.deferredWhileBusy)
        let flushed = scheduler.responseFinished()
        #expect(flushed)
        let flushedAgain = scheduler.responseFinished()
        #expect(!flushedAgain, "consumed")
    }

    @Test("response.done without a pending change does nothing; reset clears state")
    func idle() {
        var scheduler = SessionRefreshScheduler()
        let idleFinish = scheduler.responseFinished()
        #expect(!idleFinish)
        _ = scheduler.noteChange()
        scheduler.reset()
        let firedAfterReset = scheduler.fire(busy: false)
        #expect(!firedAfterReset)
    }
}
