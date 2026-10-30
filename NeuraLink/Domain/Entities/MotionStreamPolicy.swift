//
//  MotionStreamPolicy.swift
//  NeuraLink
//
//  When a generated motion stream generates, pauses and ends: keep a lead of
//  decoded frames ahead of the playhead while the character speaks, stop
//  generating a moment after the speech ends, never run longer than a reply
//  deserves, spend fewer diffusion steps when the phone is warm, and pace
//  the steps to what the phone can generate ahead of playback. Pure and
//  unit-tested; the coordinator in Data applies it.
//  See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation

struct MotionStreamPolicy: Equatable, Sendable {
    /// Seconds of decoded motion kept ahead of the playhead.
    var leadSeconds: Float = 2.5
    /// Seconds one window adds (the model's horizon).
    var windowSeconds: Float = 2
    /// The most motion one reply may generate, whatever it asked for.
    var maxReplySeconds: Float = 12
    /// Generation continues this long after the speech ends.
    var tailSeconds: Float = 1.5
    /// Diffusion steps per pressure tier; nil stops the stream.
    var stepsByTier: [RuntimePressureTier: Int] = [.normal: 10, .reduced: 4]
    /// Fewest steps worth spending: below this the motion falls apart.
    var minimumSteps = 4
    /// A window must be generated this many times faster than it plays
    /// before the lead is safe from a late window.
    var paceMargin: Float = 1.25

    /// The seconds a reply is allowed, from what the model asked for.
    func budget(requested seconds: Float?, continuous: Bool) -> Float {
        guard !continuous, let seconds, seconds.isFinite, seconds > 0 else { return maxReplySeconds }
        return min(max(seconds, windowSeconds), maxReplySeconds)
    }

    /// Diffusion steps for the tier, or nil when the stream should stop.
    func steps(for tier: RuntimePressureTier) -> Int? {
        stepsByTier[tier]
    }

    /// Steps for the next window, from the one just generated at `steps` in
    /// `wallSeconds`: as many as the measured cost affords with `paceMargin`
    /// to spare, one more than before at most, never above `ceiling`; nil
    /// when even `minimumSteps` could not keep ahead of playback, so the
    /// stream should end rather than hold a frozen body.
    func stepsAfterWindow(steps: Int, wallSeconds: Float, ceiling: Int) -> Int? {
        guard steps > 0, wallSeconds > 0, wallSeconds.isFinite else { return min(max(steps, minimumSteps), ceiling) }
        let perStep = wallSeconds / Float(steps)
        let affordable = Int((windowSeconds / (paceMargin * perStep)).rounded(.down))
        guard affordable >= minimumSteps else { return nil }
        return max(minimumSteps, min(ceiling, affordable, steps + 1))
    }

    /// Another window is wanted when the lead is short, the budget allows
    /// it, and the character is speaking or only just stopped. A stream
    /// that has not played yet always gets its first window.
    func shouldGenerateWindow(generated: Float, playhead: Float, budget: Float, speaking: Bool, silentFor: Float) -> Bool {
        guard generated < budget else { return false }
        guard generated > 0 else { return true }
        guard speaking || silentFor < tailSeconds else { return false }
        return generated - playhead < leadSeconds
    }

    /// The stream ends once nothing more will be generated and what was
    /// generated has played out.
    func shouldEnd(generated: Float, playhead: Float, budget: Float, speaking: Bool, silentFor: Float) -> Bool {
        guard generated > 0 else { return false }
        let exhausted = generated >= budget || (!speaking && silentFor >= tailSeconds)
        return exhausted && playhead >= generated
    }
}
