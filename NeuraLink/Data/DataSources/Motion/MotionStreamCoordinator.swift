//
//  MotionStreamCoordinator.swift
//  NeuraLink
//
//  Runs one generated motion stream per spoken reply on the OpenAI path:
//  the `perform_motion` tool hands it a caption, the scene gives it a
//  LiveMotionSession for the displayed character, and a background task
//  keeps `MotionStreamPolicy.leadSeconds` of decoded frames ahead of the
//  playhead until the reply is over, spending fewer diffusion steps when the
//  phone is warm. The model files load on first use and are dropped when
//  the user leaves the OpenAI path. docs/REALTIME_MOTION_PLAN.md, Phase 4.
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

    /// The models are dropped after this long without a stream.
    static let idleUnloadSeconds: Double = 600
    private var idleUnload: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStreaming else { return }
                self.unload()
                nlLog("[MotionStream] unloaded on memory warning", level: .info)
            }
        }
    }

    /// The switch is on, the OpenAI path is the one in use, Reduce Motion is
    /// off and the model files are on the device.
    var isAvailable: Bool {
        MotionSettings.shared.isEnabled && OpenAISettings.shared.isEnabled && !OpenAISettings.shared.isLocalLLMEnabled
            && !UIAccessibility.isReduceMotionEnabled && ARDYModelLocator.isComplete
    }

    var isStreaming: Bool { live != nil }

    /// Records whether the model files are present (the tool list reads it)
    /// and starts loading them when a stream could be wanted.
    func refreshAvailability() {
        UserDefaults.standard.set(ARDYModelLocator.isComplete, forKey: MotionSettings.modelsReadyKey)
        if isAvailable { prepareIfNeeded() } else if !OpenAISettings.shared.isEnabled || OpenAISettings.shared.isLocalLLMEnabled { unload() }
    }

    /// Loads the graphs and the tokenizer off the main actor, once.
    func prepareIfNeeded() {
        guard runtime == nil, loading == nil, ARDYModelLocator.isComplete else { return }
        loading = Task { [weak self] in
            guard let files = await ARDYModelLocator.files() else {
                self?.loading = nil
                return
            }
            let loaded: (ARDYMotionRuntime, ARDYPromptTokenizer)? = await Task.detached(priority: .userInitiated) {
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
                nlLog("[MotionStream] models ready on \(loaded.0.provider.label)", level: .info)
            }
            loading = nil
            if let pending = pendingRequest {
                pendingRequest = nil
                request(pending)
            }
        }
    }

    /// Drops the sessions (the OpenAI path was left, or memory is short).
    func unload() {
        cancel()
        loading?.cancel()
        loading = nil
        runtime = nil
        tokenizer = nil
    }

    // MARK: - Requests

    /// From the tool handler. Returns false when no stream can run now.
    @discardableResult
    func request(_ request: MotionStreamRequest) -> Bool {
        guard isAvailable else { return false }
        if runtime == nil {
            pendingRequest = request
            prepareIfNeeded()
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
        loop = Task { [weak self] in await self?.run(caption: request.caption) }
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
        Task { [weak self] in
            do {
                try await producer.replan(caption: request.caption)
                nlLog("[MotionStream] replanned: \(request.caption)", level: .info)
            } catch {
                nlLog("[MotionStream] replan failed: \(error)", level: .warning)
                self?.finish("replan failed")
            }
        }
    }

    private func run(caption: String) async {
        guard let producer, let live else { return }
        do {
            try await producer.start(caption: caption)
            while !Task.isCancelled {
                guard let steps = policy.steps(for: RuntimePressureMonitor.shared.tier) else {
                    finish("thermal")
                    return
                }
                if policy.shouldGenerateWindow(generated: generated, playhead: playhead, budget: budget, speaking: speaking, silentFor: silentFor) {
                    let seconds = try await producer.nextWindow(into: live, steps: steps)
                    guard !Task.isCancelled else { return }
                    let first = generated == 0
                    generated += seconds
                    if first { onReady?() }
                } else {
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch is CancellationError {
        } catch {
            nlLog("[MotionStream] window failed: \(error)", level: .warning)
            finish("generation failed")
        }
    }

    private func finish(_ reason: String) {
        let callback = onFinished
        cancel()
        callback?(reason)
    }
}
