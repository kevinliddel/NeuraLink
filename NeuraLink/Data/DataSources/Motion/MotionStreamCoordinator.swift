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
//  model files load when the Realtime session starts with gestures
//  available, behind a memory gate, and are dropped when the user leaves
//  the OpenAI path, after idling, or on a memory warning.
//  See docs/Engine/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
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
    /// Counts streams, so work started for one (a replan) cannot end the next.
    private var streamID = 0

    /// Set by the scene: whether the body is free for a stream now (no pose,
    /// entrance or episode holds it, a character is on screen). A request
    /// the scene would drop is declined up front, so the tool does not
    /// report a gesture that never plays.
    var sceneCanStart: (() -> Bool)?

    /// Streams in a row that ended because even the fewest steps were too
    /// slow, and the pressure tier of the last of them; two in a row and no
    /// more streams run at that tier or a worse one while these sessions
    /// live. A better tier (the phone cooled, Low Power Mode went off) or
    /// the next load (after ten idle minutes, a memory warning or a return
    /// to the OpenAI path) tries again, in case the pace was the moment's.
    private var tooSlowStreak = 0
    private var tooSlowTier: RuntimePressureTier = .normal

    /// The models are dropped after this long without a stream.
    static let idleUnloadSeconds: Double = 600
    private var idleUnload: Task<Void, Never>?

    /// Bytes the app must still be able to take before the model files are
    /// loaded. The weights themselves are memory-mapped from their sidecars
    /// and stay out of the footprint; what loads is the session state, and
    /// each step adds a window's activations: 11 MB and a 25 MB peak in the
    /// simulator bench of 2026-11-02. The rest of this is room for what the
    /// scene itself takes during a reply (about 250 MB on an iPhone 11).
    /// Below this the gesture is skipped rather than the app ended for memory.
    static let loadHeadroomBytes: UInt64 = 300 * 1_048_576
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
    var isPaceExhausted: Bool { tooSlowStreak >= 2 && RuntimePressureMonitor.shared.tier >= tooSlowTier }

    /// Records whether the model files are present (the tool list reads it),
    /// drops the models when the OpenAI path is no longer the one in use,
    /// and clears a superseded download. Loading is `prepareIfNeeded`'s, at
    /// the Realtime session start.
    func refreshAvailability() {
        UserDefaults.standard.set(ARDYModelLocator.isComplete, forKey: MotionSettings.modelsReadyKey)
        if !OpenAISettings.shared.isEnabled || OpenAISettings.shared.isLocalLLMEnabled { unload() }
        Task.detached(priority: .utility) { MotionModelAccess.removeSupersededDownloads() }
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
                    + "\(MemoryFootprint.megabytes(Self.loadHeadroomBytes)) needed (\(MemoryFootprint.summary))",
                level: .warning)
            return false
        }
        loading = Task(priority: .utility) { [weak self] in
            guard let files = await ARDYModelLocator.files() else {
                guard let self, !Task.isCancelled else { return }
                loading = nil
                pendingRequest = nil
                return
            }
            let started = ContinuousClock.now
            // The CPU provider: it memory-maps the weights from their sidecars
            // and reads them in place, where the CoreML provider compiles a
            // copy of the graph (and the shipped runtime's computed float16
            // wrong, bench of 2026-11-02) and XNNPACK brings spinning threads
            // of its own; the CPU path keeps every step on the bridge's two
            // threads, at user-initiated QoS.
            let loaded: (ARDYMotionRuntime, ARDYPromptTokenizer)? = await Task.detached(priority: .utility) {
                do {
                    let runtime = try ARDYMotionRuntime(files: files, provider: .cpu)
                    let tokenizer = try ARDYPromptTokenizer(tokenizerJSON: files.tokenizer, configJSON: files.tokenizerConfig)
                    return (runtime, tokenizer)
                } catch {
                    nlLog("[MotionStream] model load failed: \(error)", level: .warning)
                    return nil
                }
            }.value
            // An unload while the graphs were loading wins: nothing is
            // installed, and a newer load's handle is left alone.
            guard let self, !Task.isCancelled else { return }
            loading = nil
            let pending = pendingRequest
            pendingRequest = nil
            // A failed load drops the request: replaying it would only start
            // the same load again.
            guard let loaded else { return }
            runtime = loaded.0
            tokenizer = loaded.1
            MotionStreamHold.shared.set(nil)
            let read = loaded.0.weightsReadThrough
            nlLog(
                "[MotionStream] models ready on \(loaded.0.provider.label) in \(Self.seconds(since: started)) s "
                    + "(weights \(MemoryFootprint.megabytes(UInt64(read.bytes))) read through in \(Self.format(Float(read.seconds))) s): "
                    + "\(MemoryFootprint.summary), available \(MemoryFootprint.megabytes(MemoryFootprint.availableBytes))",
                level: .info)
            // The idle clock starts with the models, not with the first stream.
            scheduleIdleUnload()
            if let pending { request(pending) }
        }
        return true
    }

    /// Drops the sessions (the OpenAI path was left, memory is short, the
    /// files were removed, or nothing ran for a while); the next load judges
    /// the pace afresh. A running stream is finished, so the scene takes the
    /// body back instead of holding the last pose.
    func unload() {
        if isStreaming { finish("models unloaded") } else { cancel() }
        loading?.cancel()
        loading = nil
        pendingRequest = nil
        runtime = nil
        tokenizer = nil
        tooSlowStreak = 0
        idleUnload?.cancel()
        idleUnload = nil
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
                + "\(MemoryFootprint.summary), available \(MemoryFootprint.megabytes(available))",
            level: .warning)
    }

    // MARK: - Requests

    /// From the tool handler. Returns false when no stream can run now,
    /// including when the scene would drop it (a pose, the entrance or an
    /// episode holds the body).
    @discardableResult
    func request(_ request: MotionStreamRequest) -> Bool {
        guard isAvailable else { return false }
        if live != nil {
            replan(with: request)
            return true
        }
        guard sceneCanStart?() ?? true else {
            nlLog("[MotionStream] declined: the body is owned elsewhere", level: .info)
            return false
        }
        // The pace pause has lifted (a cooler tier, or a reload): the card
        // stops saying so as this stream tries.
        clearPaceHold()
        if runtime == nil {
            guard prepareIfNeeded() else { return false }
            pendingRequest = request
            return true
        }
        NotificationCenter.default.post(name: .liveMotionRequested, object: nil, userInfo: ["request": request])
        return true
    }

    private func clearPaceHold() {
        if case .pace = MotionStreamHold.shared.current { MotionStreamHold.shared.set(nil) }
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
        streamID += 1
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
        // User-initiated priority: the task's thread is one of the runtime's
        // two intra-op threads, and at utility the scheduler would keep it on
        // an efficiency core (1.1 s a step on an iPhone 11); the render loop
        // runs user-interactive and still goes first.
        loop = Task(priority: .userInitiated) { [weak self] in await self?.run(caption: request.caption) }
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
        let stream = streamID
        Task(priority: .userInitiated) { [weak self] in
            do {
                try await producer.replan(caption: request.caption)
                nlLog("[MotionStream] replanned: \(request.caption)", level: .info)
            } catch {
                nlLog("[MotionStream] replan failed: \(error)", level: .warning)
                // Only the stream it was for; a newer one carries on.
                guard let self, streamID == stream else { return }
                finish("replan failed")
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
                let tier = RuntimePressureMonitor.shared.tier
                guard let ceiling = policy.steps(for: tier) else {
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
                    tooSlowTier = tier
                    rememberPace(policy.minimumSteps)
                    MotionStreamHold.shared.set(.pace(secondsPerWindow: wall, tier: tier))
                    nlLog(
                        "[MotionStream] too slow: window \(windows) took \(Self.format(wall)) s at \(steps) steps (\(tier)); "
                            + "stream \(tooSlowStreak) of 2 before gestures pause at this tier until the models reload",
                        level: .warning)
                    finish("too slow")
                    return
                }
                if !first {
                    tooSlowStreak = 0
                    clearPaceHold()
                }
                nlLog(
                    "[MotionStream] window \(windows): \(Self.format(wall)) s at \(steps) steps → \(next) (ceiling \(ceiling), \(tier)), "
                        + "lead \(Self.format(generated - playhead)) s, \(MemoryFootprint.summary)",
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
