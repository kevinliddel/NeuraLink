//
//  TranscriptTypewriter.swift
//  NeuraLink
//
//  Coalesces per-token transcript updates into a single ~33 fps reveal.
//
//  Fix 2 (typewriter): the LLM emits tokens in bursts (especially during
//  prefill warmup); revealing a fixed fraction of the backlog each tick gives
//  a smooth, even "typing" cadence instead of choppy word-bursts.
//
//  Fix 3 (coalesce): the engine callback (LlamaBridge already hops to the main
//  actor per token to call the delegate) used to spawn ANOTHER per-token
//  `Task { @MainActor }` to mutate `aiTranscript` + trigger emotions — i.e. a
//  SwiftUI invalidation on every token. `enqueue()` is now a cheap lock+append
//  with no per-token hop; a single tick task does all the main-actor work at
//  33 fps, so the avatar/UI re-render at most ~33×/s, not once per token.
//

import Foundation

final class TranscriptTypewriter: @unchecked Sendable {

    private let lock = NSLock()
    private var pendingText = ""
    private var pendingEmotions: [(String, Float)] = []
    private var target = ""
    private var shownCount = 0
    private var generationActive = false
    private var tickRunning = false
    /// Bumped by reset()/setImmediate() so a tick from a superseded turn exits.
    private var generation = 0

    /// MainActor-confined: only touched inside the @MainActor methods below.
    private weak var state: RealtimeChatState?

    /// Set once at wiring time. `state` is read only on the main actor.
    func bind(_ state: RealtimeChatState) { self.state = state }

    // MARK: - Producer (engine-callback thread)

    /// Cheap append from the token callback — no per-token MainActor hop.
    /// Starts the single reveal tick on the first enqueue of a turn.
    func enqueue(text: String, emotions: [(String, Float)]) {
        lock.lock()
        pendingText += text
        if !emotions.isEmpty { pendingEmotions.append(contentsOf: emotions) }
        generationActive = true
        let needStart = !tickRunning
        if needStart { tickRunning = true }
        let gen = generation
        lock.unlock()
        if needStart { Task { @MainActor in await self.runTick(gen) } }
    }

    /// Generation finished — the tick reveals the remaining backlog then stops.
    func endGeneration() {
        lock.lock(); generationActive = false; lock.unlock()
    }

    // MARK: - Turn boundaries (main actor)

    /// Clear all state for a new turn and blank the transcript.
    @MainActor func reset() {
        lock.lock()
        generation &+= 1
        pendingText = ""; pendingEmotions = []
        target = ""; shownCount = 0
        generationActive = false; tickRunning = false
        lock.unlock()
        state?.aiTranscript = ""
    }

    /// Replace the transcript immediately (e.g. a tool-call result), skipping
    /// the gradual reveal and cancelling any in-flight tick.
    @MainActor func setImmediate(_ text: String) {
        lock.lock()
        generation &+= 1
        pendingText = ""; pendingEmotions = []
        target = text; shownCount = text.count
        generationActive = false; tickRunning = false
        lock.unlock()
        state?.aiTranscript = text
    }

    // MARK: - Reveal tick (main actor)

    @MainActor private func runTick(_ gen: Int) async {
        while true {
            lock.lock()
            guard gen == generation else { lock.unlock(); return }  // superseded
            if !pendingText.isEmpty { target += pendingText; pendingText = "" }
            let emotions = pendingEmotions; pendingEmotions = []
            let active = generationActive
            let remaining = target.count - shownCount
            var reveal: String?
            if remaining > 0 {
                // Reveal ~1/6 of the backlog per tick: catches up on bursts,
                // eases off on a trickle — a natural typing cadence.
                shownCount = min(target.count, shownCount + max(1, remaining / 6))
                reveal = String(target.prefix(shownCount))
            }
            let finished = !active && pendingText.isEmpty && shownCount >= target.count
            if finished { tickRunning = false }
            lock.unlock()

            if let s = state {
                if s.status == .thinking { s.status = .speaking }
                for (emotion, duration) in emotions {
                    s.triggerEmotion(emotion, duration: duration)
                }
                if let reveal { s.aiTranscript = reveal }
            }

            if finished { return }
            try? await Task.sleep(nanoseconds: 30_000_000)  // ~33 fps
        }
    }
}
