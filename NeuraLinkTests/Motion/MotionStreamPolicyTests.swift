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

    @Test("Steps follow the measured pace of a window")
    func pace() {
        // 0.5 s for 2 s of motion at 10 steps: plenty of room, the ceiling holds.
        #expect(policy.stepsAfterWindow(steps: 10, wallSeconds: 0.5, ceiling: 10) == 10)
        // 3 s at 10 steps: 0.3 s a step; 2 s / (1.25 × 0.3) affords 5.
        #expect(policy.stepsAfterWindow(steps: 10, wallSeconds: 3.0, ceiling: 10) == 5)
        // Room to spare climbs back one step at a time.
        #expect(policy.stepsAfterWindow(steps: 5, wallSeconds: 0.8, ceiling: 10) == 6)
        // The tier's ceiling still caps it.
        #expect(policy.stepsAfterWindow(steps: 10, wallSeconds: 1.0, ceiling: 4) == 4)
        // 1.64 s at the fewest steps (0.41 s a step, under the margin but
        // ahead of the 2 s the window plays): they run on.
        #expect(policy.stepsAfterWindow(steps: 4, wallSeconds: 1.64, ceiling: 10) == 4)
        #expect(policy.stepsAfterWindow(steps: 4, wallSeconds: 1.99, ceiling: 4) == 4)
        // 2 s or more at the fewest steps: the lead would shrink every window.
        #expect(policy.stepsAfterWindow(steps: 4, wallSeconds: 2.0, ceiling: 10) == nil)
        #expect(policy.stepsAfterWindow(steps: 4, wallSeconds: 2.36, ceiling: 4) == nil)
        // 2.6 s at the fewest steps: even they cannot keep up.
        #expect(policy.stepsAfterWindow(steps: 4, wallSeconds: 2.6, ceiling: 10) == nil)
        // Measured at more steps, the verdict is still about the fewest.
        #expect(policy.stepsAfterWindow(steps: 10, wallSeconds: 4.5, ceiling: 10) == 4, "0.45 s a step: 4 fit, 5 would not")
        #expect(policy.stepsAfterWindow(steps: 10, wallSeconds: 5.5, ceiling: 10) == nil, "0.55 s a step: 4 take 2.2 s")
        // No usable measurement: keep what was asked, within bounds.
        #expect(policy.stepsAfterWindow(steps: 10, wallSeconds: 0, ceiling: 10) == 10)
        #expect(policy.stepsAfterWindow(steps: 2, wallSeconds: .nan, ceiling: 10) == policy.minimumSteps)
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
        #expect(policy.shouldEnd(generated: 4, playhead: 3.95, budget: 4, speaking: true, silentFor: 0), "on the last frame")
        #expect(!policy.shouldEnd(generated: 4, playhead: 3.9, budget: 4, speaking: true, silentFor: 0), "a frame still to play")
    }

    @Test("A buffer played to its end ends the stream (the playhead stops on the last frame)")
    func endsOnTheBuffersLastFrame() {
        let buffer = LiveMotionBuffer(framesPerSecond: 1 / policy.frameSeconds)
        let rest = LiveMotionPose(rotations: [], hipsTranslation: .zero)
        buffer.append([LiveMotionPose](repeating: rest, count: Int(policy.windowSeconds / policy.frameSeconds)))
        _ = buffer.samplePlayer(at: 0)
        _ = buffer.samplePlayer(at: 10)  // the player's clock runs on; the buffer's waits at its end
        #expect(buffer.playhead < policy.windowSeconds, "the playhead never reaches the seconds generated")
        #expect(policy.shouldEnd(
            generated: policy.windowSeconds, playhead: buffer.playhead, budget: policy.windowSeconds, speaking: true, silentFor: 0))
    }
}
