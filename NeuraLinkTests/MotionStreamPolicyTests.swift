//
//  MotionStreamPolicyTests.swift
//  NeuraLinkTests
//
//  The scheduling rules of a generated motion stream: a first window
//  always, more while the lead is short and the character speaks or has
//  just stopped, nothing past the reply's budget, and the end once the
//  buffered motion has played out. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Testing

@testable import NeuraLink

@Suite("Motion stream policy")
struct MotionStreamPolicyTests {
    private let policy = MotionStreamPolicy()

    @Test("Budget follows the request within the reply cap")
    func budget() {
        #expect(policy.budget(requested: 6, continuous: false) == 6)
        #expect(policy.budget(requested: 30, continuous: false) == policy.maxReplySeconds)
        #expect(policy.budget(requested: 0.5, continuous: false) == policy.windowSeconds)
        #expect(policy.budget(requested: nil, continuous: false) == policy.maxReplySeconds)
        #expect(policy.budget(requested: 4, continuous: true) == policy.maxReplySeconds)
    }

    @Test("Steps per pressure tier")
    func steps() {
        #expect(policy.steps(for: .normal) == 10)
        #expect(policy.steps(for: .reduced) == 4)
        #expect(policy.steps(for: .minimal) == nil)
    }

    @Test("Generates the first window, then keeps a lead while speaking")
    func generation() {
        #expect(policy.shouldGenerateWindow(generated: 0, playhead: 0, budget: 6, speaking: false, silentFor: 10))
        #expect(policy.shouldGenerateWindow(generated: 2, playhead: 0.5, budget: 6, speaking: true, silentFor: 0))
        #expect(!policy.shouldGenerateWindow(generated: 4, playhead: 0.5, budget: 6, speaking: true, silentFor: 0), "lead is long enough")
        #expect(policy.shouldGenerateWindow(generated: 4, playhead: 2, budget: 6, speaking: true, silentFor: 0))
        #expect(!policy.shouldGenerateWindow(generated: 6, playhead: 5, budget: 6, speaking: true, silentFor: 0), "budget spent")
        #expect(policy.shouldGenerateWindow(generated: 2, playhead: 1.5, budget: 6, speaking: false, silentFor: 1), "within the tail")
        #expect(!policy.shouldGenerateWindow(generated: 2, playhead: 1.5, budget: 6, speaking: false, silentFor: 2), "past the tail")
    }

    @Test("Ends after the buffered motion plays out")
    func ending() {
        #expect(!policy.shouldEnd(generated: 0, playhead: 0, budget: 6, speaking: false, silentFor: 5), "nothing generated yet")
        #expect(!policy.shouldEnd(generated: 6, playhead: 4, budget: 6, speaking: false, silentFor: 5), "still playing")
        #expect(policy.shouldEnd(generated: 6, playhead: 6, budget: 6, speaking: true, silentFor: 0), "budget spent and played")
        #expect(policy.shouldEnd(generated: 4, playhead: 4, budget: 6, speaking: false, silentFor: 2), "silence past the tail and played")
        #expect(!policy.shouldEnd(generated: 4, playhead: 4, budget: 6, speaking: true, silentFor: 0), "speaking: more may come")
    }
}
