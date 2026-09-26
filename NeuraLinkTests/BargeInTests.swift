//
//  BargeInTests.swift
//  NeuraLinkTests
//
//  Pure-logic tests for local barge-in (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §A2).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Local barge-in")
struct BargeInTests {

    @Test("Voice start inside the TTS onset guard is ignored")
    func onsetGuard() {
        var arbiter = BargeInArbiter()
        let ignoredA = arbiter.voiceStarted(at: 10.2, playbackStartedAt: 10.0)
        #expect(!ignoredA)
        let ignoredB = arbiter.voiceStarted(at: 10.2, playbackStartedAt: nil)
        #expect(!ignoredB)
        let opened = arbiter.voiceStarted(at: 11.0, playbackStartedAt: 10.0)
        #expect(opened)
        #expect(arbiter.candidateSince == 11.0)
    }

    @Test("Commits only when mic energy dominates playback over the window")
    func energyDecision() {
        var arbiter = BargeInArbiter()
        _ = arbiter.voiceStarted(at: 11.0, playbackStartedAt: 10.0)
        let early = arbiter.observe(micRMS: 0.2, playbackRMS: 0.05, at: 11.1)
        #expect(early == .none)
        let commit = arbiter.observe(micRMS: 0.2, playbackRMS: 0.05, at: 11.3)
        #expect(commit == .commit)
        #expect(arbiter.candidateSince == nil)

        _ = arbiter.voiceStarted(at: 12.0, playbackStartedAt: 10.0)
        _ = arbiter.observe(micRMS: 0.05, playbackRMS: 0.05, at: 12.1)
        let reject = arbiter.observe(micRMS: 0.05, playbackRMS: 0.05, at: 12.3)
        #expect(reject == .reject)

        _ = arbiter.voiceStarted(at: 13.0, playbackStartedAt: 10.0)
        let silence = arbiter.observe(micRMS: 0.001, playbackRMS: 0.0, at: 13.3)
        #expect(silence == .reject, "near-silent mic never commits even with silent playback")
    }

    @Test("Echo guard rejects transcripts that repeat the assistant's last words")
    func echoGuard() {
        let assistant = "Sure, I can help you plan the trip to Kyoto next spring if you like."
        #expect(BargeInEchoGuard.isEcho(transcript: "trip to Kyoto next spring", assistantText: assistant))
        #expect(!BargeInEchoGuard.isEcho(transcript: "actually wait, what about Osaka instead", assistantText: assistant))
        #expect(BargeInEchoGuard.isEcho(transcript: "", assistantText: assistant), "empty transcript is noise")
        #expect(!BargeInEchoGuard.isEcho(transcript: "hello there", assistantText: ""))
    }
}
