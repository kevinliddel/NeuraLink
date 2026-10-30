//
//  MotionStreamCoordinator.swift
//  NeuraLink
//
//  Runs one generated motion stream per spoken reply on the OpenAI path:
//  the `perform_motion` tool hands it a caption, the scene gives it a
//  LiveMotionSession for the displayed character, and a background task
//  keeps `MotionStreamPolicy.leadSeconds` of decoded frames ahead of the
//  playhead until the reply is over, spending fewer diffusion steps when the
//  phone is warm or cannot generate a window faster than it plays. The
//  model files load when the Realtime session starts, behind a memory gate,
//  and are dropped when the user leaves the OpenAI path, after idling, or
//  on a memory warning. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Observation
import UIKit

/// What the tool asked for.
struct MotionStreamRequest: Sendable, Equatable {
    let caption: String
    let seconds: Float?
    let continuous: Bool
}

extension Notification.Name {
    /// Posted with a `MotionStreamRequest` under `userInfo["request"]`; the
    /// scene answers with a live session for its character.
    static let liveMotionRequested = Notification.Name("LiveMotionRequested")
}

/// A source of windows the coordinator can drive: the real
/// MotionGenerationSession, or a stub in tests.
protocol MotionWindowProducer: Sendable {
    func start(caption: String) async throws
    func replan(caption: String) async throws
    /// Appends one window to `live` and returns the seconds it added.
    func nextWindow(into live: LiveMotionSession, steps: Int) async throws -> Float
}

extension MotionGenerationSession: MotionWindowProducer {
    func start(caption: String) throws {
        try start(caption: caption, seed: nil)
    }

    func nextWindow(into live: LiveMotionSession, steps: Int) async throws -> Float {
        self.steps = steps
        let window = try nextWindow(into: live)
        return Float(window.frames) / framesPerSecond
    }
}

/// Why no stream will run right now, for the Settings card: the phone is
/// short of memory for the model, or it generates too slowly to keep up.
@Observable
final class MotionStreamHold {
    static let shared = MotionStreamHold()

    enum Reason: Equatable {
        case memory(availableMB: Int)
        case pace(secondsPerWindow: Float)
    }

    private(set) var current: Reason?

    private init() {}

    var reason: String? {
        switch current {
        case .none: return nil
        case .memory(let availableMB):
            let needed = MotionStreamCoordinator.loadHeadroomBytes / 1_048_576
            return "Paused: \(availableMB) MB of memory free, about \(needed) MB needed to load the model."
        case .pace(let seconds):
            return String(format: "Paused: this phone took %.1f s to generate 2 s of motion, too slow to keep up with speech.", seconds)
        }
    }

    func set(_ reason: Reason?) {
        guard reason != current else { return }
        current = reason
    }
}

@MainActor
final class MotionStreamCoordinator {
    static let shared = MotionStreamCoordinator()

    var policy = MotionStreamPolicy()
    private(set) var runtime: ARDYMotionRuntime?
    private var tokenizer: ARDYPromptTokenizer?
    private var loading: Task<Void, Never>?
    private var pendingRequest: MotionStreamRequest?

    // The running stream.
    private var producer: (any MotionWindowProducer)?
    private var live: LiveMotionSession?
    private var loop: Task<Void, Never>?
    private var generated: Float = 0
    private var playhead: Float = 0
    private var budget: Float = 0
    private var speaking = false
    private var silentFor: Float = 0
    private var onReady: (() -> Void)?
    private var onFinished: ((String) -> Void)?

    /// Streams in a row that ended because even the fewest steps were too
    /// slow; two in a row and no more streams run this launch.
    private var tooSlowStreak = 0

    /// The models are dropped after this long without a stream.
    static let idleUnloadSeconds: Double = 600
    private var idleUnload: Task<Void, Never>?

    /// Bytes the app must still be able to take before the model files are
    /// loaded: the fp32 graphs weigh about 1.2 GB once the sessions are up,
    /// and a window's activations come on top. Below this the gesture is
    /// skipped rather than the app ended for memory.
    static let loadHeadroomBytes: UInt64 = 1_500 * 1_048_576
    /// A stream ends when the app's remaining allowance falls under this.
    static let streamMemoryFloorBytes: UInt64 = 160 * 1_048_576
    /// Diffusion steps that kept up last time, so the next stream starts
    /// there instead of discovering the phone's pace again.
    static let paceStepsKey = "motion.generated.paceSteps"
    /// The first window includes the text encode and the runtime's warm-up;
    /// this share of its time is taken as the steady cost of its steps.
    static let firstWindowSteadyShare: Float = 0.6

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMemoryWarning() }
        }
    }

    /// Developer hook: the `nl.debug.motionCaption` default (a launch argument
    /// in the scheme) plays this caption once the character is on screen,
    /// with no Realtime session and whatever the switch says; the model files
    /// are still required. Device checks without an API key.
    static let debugCaptionKey = "nl.debug.motionCaption"
    var debugCaption: String? {
        let caption = UserDefaults.standard.string(forKey: Self.debugCaptionKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return caption?.isEmpty == false ? caption : nil
    }

    /// The switch is on, the OpenAI path is the one in use, Reduce Motion is
    /// off, the model files are on the device (or the developer hook is set)
    /// and this phone has not proven too slow twice running.
    var isAvailable: Bool {
        guard ARDYModelLocator.isComplete, !isPaceExhausted else { return false }
        if debugCaption != nil { return true }
        return MotionSettings.shared.isEnabled && OpenAISettings.shared.isEnabled && !OpenAISettings.shared.isLocalLLMEnabled
            && !UIAccessibility.isReduceMotionEnabled
    }

    var isStreaming: Bool { live != nil }
    var isPaceExhausted: Bool { tooSlowStreak >= 2 }

    /// Records whether the model files are present (the tool list reads it)
    /// and drops the models when the OpenAI path is no longer the one in
    /// use. Loading is `prepareIfNeeded`'s, at the Realtime session start.
    func refreshAvailability() {
        UserDefaults.standard.set(ARDYModelLocator.isComplete, forKey: MotionSettings.modelsReadyKey)
        if !OpenAISettings.shared.isEnabled || OpenAISettings.shared.isLocalLLMEnabled { unload() }
    }

    /// Loads the graphs and the tokenizer off the main actor, at utility
    /// priority, once, when the phone has room for them. Returns false when
    /// nothing will load.
    @discardableResult
    func prepareIfNeeded() -> Bool {
        if runtime != nil || loading != nil { return true }
        guard ARDYModelLocator.isComplete else { return false }
        if let available = MemoryFootprint.availableBytes, available < Self.loadHeadroomBytes {
            MotionStreamHold.shared.set(.memory(availableMB: Int(available / 1_048_576)))
            nlLog(
                "[MotionStream] not loading the motion model: \(MemoryFootprint.megabytes(available)) available, "
                    + "\(MemoryFootprint.megabytes(Self.loadHeadroomBytes)) needed (footprint \(MemoryFootprint.megabytes(MemoryFootprint.physicalBytes)))",
                level: .warning)
            return false
        }
        loading = Task(priority: .utility) { [weak self] in
            guard let files = await ARDYModelLocator.files() else {
                self?.loading = nil
                return
            }
            let started = ContinuousClock.now
            let loaded: (ARDYMotionRuntime, ARDYPromptTokenizer)? = await Task.detached(priority: .utility) {
                do {
                    let runtime = try ARDYMotionRuntime(files: files, provider: .coreML)
                    let tokenizer = try ARDYPromptTokenizer(tokenizerJSON: files.tokenizer, configJSON: files.tokenizerConfig)
                    return (runtime, tokenizer)
                } catch {
                    nlLog("[MotionStream] model load failed: \(error)", level: .warning)
                    return nil
                }
            }.value
            guard let self else { return }
            if let loaded {
                runtime = loaded.0
                tokenizer = loaded.1
                MotionStreamHold.shared.set(nil)
                nlLog(
                    "[MotionStream] models ready on \(loaded.0.provider.label) in \(Self.seconds(since: started)) s: "
                        + "footprint \(MemoryFootprint.megabytes(MemoryFootprint.physicalBytes)), available \(MemoryFootprint.megabytes(MemoryFootprint.availableBytes))",
                    level: .info)
            }
            loading = nil
            if let pending = pendingRequest {
                pendingRequest = nil
                request(pending)
            }
        }
        return true
    }

    /// Drops the sessions (the OpenAI path was left, or memory is short).
    func unload() {
        cancel()
        loading?.cancel()
        loading = nil
        runtime = nil
        tokenizer = nil
    }

    /// A running stream is cut and the models go, whatever the state: a
    /// gesture lost beats the app ended for memory.
    private func handleMemoryWarning() {
        let wasStreaming = isStreaming
        if wasStreaming { finish("memory warning") }
        let hadModels = runtime != nil || loading != nil
        unload()
        guard hadModels else { return }
        let available = MemoryFootprint.availableBytes
        MotionStreamHold.shared.set(.memory(availableMB: Int((available ?? 0) / 1_048_576)))
        nlLog(
            "[MotionStream] unloaded on memory warning\(wasStreaming ? " mid-stream" : ""): "
                + "footprint \(MemoryFootprint.megabytes(MemoryFootprint.physicalBytes)), available \(MemoryFootprint.megabytes(available))",
            level: .warning)
    }

    // MARK: - Requests

    /// From the tool handler. Returns false when no stream can run now.
    @discardableResult
    func request(_ request: MotionStreamRequest) -> Bool {
        guard isAvailable else { return false }
        if runtime == nil {
            guard prepareIfNeeded() else { return false }
            pendingRequest = request
            return true
        }
        if live != nil {
            replan(with: request)
            return true
        }
        NotificationCenter.default.post(name: .liveMotionRequested, object: nil, userInfo: ["request": request])
        return true
    }

    /// The scene's answer to `.liveMotionRequested`: a live session for its
    /// character. `onReady` fires once the first window is decoded (the
    /// scene crossfades onto the clip); `onFinished` when the stream is over.
    func begin(
        _ request: MotionStreamRequest, live session: LiveMotionSession, producer source: (any MotionWindowProducer)? = nil,
        onReady ready: @escaping () -> Void, onFinished finished: @escaping (String) -> Void
    ) {
        cancel()
        guard let source = source ?? makeProducer() else {
            finished("no runtime")
            return
        }
        producer = source
        live = session
        onReady = ready
        onFinished = finished
        generated = 0
        playhead = 0
        silentFor = 0
        speaking = true
        budget = policy.budget(requested: request.seconds, continuous: request.continuous)
        idleUnload?.cancel()
        // Utility priority: the denoiser must never outrank the render loop.
        loop = Task(priority: .utility) { [weak self] in await self?.run(caption: request.caption) }
    }

    /// Per frame from the scene while a stream plays.
    func tick(playhead position: Float, speaking isSpeaking: Bool, deltaTime: Float) {
        playhead = position
        if isSpeaking {
            speaking = true
            silentFor = 0
        } else {
            speaking = false
            silentFor += deltaTime
        }
        if live != nil, policy.shouldEnd(generated: generated, playhead: playhead, budget: budget, speaking: speaking, silentFor: silentFor) {
            finish("played out")
        }
    }

    /// Stops generating and forgets the stream; the scene already took the body back.
    func cancel() {
        loop?.cancel()
        loop = nil
        producer = nil
        live = nil
        onReady = nil
        onFinished = nil
        scheduleIdleUnload()
    }

    /// Frees the sessions when no stream has run for `idleUnloadSeconds`.
    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        guard runtime != nil else { return }
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnloadSeconds))
            guard let self, !Task.isCancelled, !isStreaming else { return }
            unload()
            nlLog("[MotionStream] unloaded after idling", level: .info)
        }
    }

    // MARK: - The loop

    private func makeProducer() -> (any MotionWindowProducer)? {
        guard let runtime, let tokenizer else { return nil }
        return MotionGenerationSession(runtime: runtime, tokenizer: tokenizer, seed: UInt32.random(in: 1...UInt32.max))
    }

    private func replan(with request: MotionStreamRequest) {
        guard let producer else { return }
        budget = min(policy.maxReplySeconds, generated + policy.budget(requested: request.seconds, continuous: request.continuous))
        Task(priority: .utility) { [weak self] in
            do {
                try await producer.replan(caption: request.caption)
                nlLog("[MotionStream] replanned: \(request.caption)", level: .info)
            } catch {
                nlLog("[MotionStream] replan failed: \(error)", level: .warning)
                self?.finish("replan failed")
            }
        }
    }

    /// Steps the last stream settled on, if any, else the tier's.
    private func startingSteps(ceiling: Int) -> Int {
        let learned = UserDefaults.standard.integer(forKey: Self.paceStepsKey)
        return learned > 0 ? min(learned, ceiling) : ceiling
    }

    private func rememberPace(_ steps: Int) {
        UserDefaults.standard.set(steps, forKey: Self.paceStepsKey)
    }

    private func run(caption: String) async {
        guard let producer, let live else { return }
        do {
            try await producer.start(caption: caption)
            var steps = policy.steps(for: RuntimePressureMonitor.shared.tier).map { startingSteps(ceiling: $0) } ?? 0
            var windows = 0
            while !Task.isCancelled {
                guard let ceiling = policy.steps(for: RuntimePressureMonitor.shared.tier) else {
                    finish("thermal")
                    return
                }
                steps = min(max(steps, policy.minimumSteps), ceiling)
                guard policy.shouldGenerateWindow(generated: generated, playhead: playhead, budget: budget, speaking: speaking, silentFor: silentFor) else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                if let available = MemoryFootprint.availableBytes, available < Self.streamMemoryFloorBytes {
                    nlLog("[MotionStream] ending: \(MemoryFootprint.megabytes(available)) left before the memory limit", level: .warning)
                    finish("memory")
                    unload()
                    return
                }
                let started = ContinuousClock.now
                let seconds = try await producer.nextWindow(into: live, steps: steps)
                guard !Task.isCancelled else { return }
                let wall = Self.seconds(since: started)
                let first = generated == 0
                generated += seconds
                windows += 1
                if first { onReady?() }
                guard let next = pace(after: wall, steps: steps, ceiling: ceiling, first: first) else {
                    tooSlowStreak += 1
                    rememberPace(policy.minimumSteps)
                    MotionStreamHold.shared.set(.pace(secondsPerWindow: wall))
                    nlLog("[MotionStream] too slow: window \(windows) took \(Self.format(wall)) s at \(steps) steps; stream \(tooSlowStreak) of 2 before gestures stop", level: .warning)
                    finish("too slow")
                    return
                }
                if !first { tooSlowStreak = 0 }
                nlLog(
                    "[MotionStream] window \(windows): \(Self.format(wall)) s at \(steps) steps → \(next), lead \(Self.format(generated - playhead)) s, "
                        + "footprint \(MemoryFootprint.megabytes(MemoryFootprint.physicalBytes))",
                    level: .info)
                steps = next
                rememberPace(next)
            }
        } catch is CancellationError {
        } catch {
            nlLog("[MotionStream] window failed: \(error)", level: .warning)
            finish("generation failed")
        }
    }

    /// Steps for the next window. The first window's time is discounted for
    /// the encode and warm-up it carries and never ends the stream.
    private func pace(after wall: Float, steps: Int, ceiling: Int, first: Bool) -> Int? {
        if first {
            return policy.stepsAfterWindow(steps: steps, wallSeconds: wall * Self.firstWindowSteadyShare, ceiling: ceiling) ?? policy.minimumSteps
        }
        return policy.stepsAfterWindow(steps: steps, wallSeconds: wall, ceiling: ceiling)
    }

    private func finish(_ reason: String) {
        let callback = onFinished
        cancel()
        callback?(reason)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Float {
        let elapsed = ContinuousClock.now - start
        return Float(elapsed.components.seconds) + Float(elapsed.components.attoseconds) / 1e18
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
}
