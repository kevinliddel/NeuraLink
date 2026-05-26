//
//  LocalLLMManager.swift
//  NeuraLink
//
//  Created by Dedicatus on 23/04/2026.
//

import AVFoundation
import Foundation

/// Orchestrates the local LLM inference loop and local Text-to-Speech playback.
final class LocalLLMManager: NSObject, @unchecked Sendable {
    static let shared = LocalLLMManager()

    // Routes to the engine matching the user's explicit model selection.
    // Qwen (stateful, KV-cache) requires iOS 18+; falls back to Llama on iOS 17.
    // Llama is always available as the memory-safe fallback for 4 GB devices.
    private static func makeEngine() -> any LLMEngineProtocol {
        let manager = LocalModelDownloadManager.shared
        guard manager.isAvailable else {
            // No model is ready yet; return GGUF engine as a safe placeholder.
            return GGUFLlamaEngine.shared
        }

        switch manager.selectedConfig {
        case .qwen2b:
            return GGUFQwenEngine.shared as any LLMEngineProtocol
        case .qwen3b:
            return GGUFQwen3BEngine.shared as any LLMEngineProtocol
        case .qwen7b:
            // Speculative decoding (1.5B draft + 7B target) auto-activates
            // when the 1.5B Qwen is also on disk — typically 2–3× decode
            // throughput at identical output quality. Falls back to the
            // plain 7B engine when the draft model isn't available.
            if GGUFSpeculativeEngine.canActivate {
                return GGUFSpeculativeEngine.shared as any LLMEngineProtocol
            }
            return GGUFQwen7BEngine.shared as any LLMEngineProtocol
        case .llama1b:
            return GGUFLlamaEngine.shared
        case .japaneseLlama1b:
            return GGUFJapaneseLlamaEngine.shared
        }
    }

    // Audio Engine for TTS Lip-sync
    internal let audioEngine = AVAudioEngine()
    internal let playerNode = AVAudioPlayerNode()

    // State
    let state = RealtimeChatState.shared
    var llmEngine: any LLMEngineProtocol = LocalLLMManager.makeEngine()

    let whisperManager = LocalWhisperManager.shared
    internal let sileroVAD = SileroVADProcessor()

    // Accumulate text for TTS chunking (e.g., speak sentence by sentence)
    var ttsBuffer = ""

    // Buffers tokens that may be part of an [emotion:n] tag.
    // Tag characters are intercepted here and never reach ttsBuffer or aiTranscript.
    var tagBuffer = ""

    // Audio Capture State
    var hardwareInputFormat: AVAudioFormat?
    var recordingBuffer = [Float]()
    var isRecordingVoice = false
    let recordingLock = NSLock()

    // Concurrency guard for startListening
    let stateLock = NSLock()
    var isPreparingOrActive = false

    // Partial transcription state
    internal var isTranscribingPartial = false
    internal var lastPartialTranscribedCount = 0

    // Lightweight turn-level latency metrics (user text → token/audio)
    internal var turnStartNs: UInt64?
    internal var firstTokenLatencyLogged = false
    internal var firstAudioLatencyLogged = false

    // Self-loop guard: timestamp (system uptime) until which mic frames are
    // dropped before reaching the VAD. Bumped forward by the audio tap on
    // every .thinking/.speaking sample observed, then naturally expires
    // ~800 ms after the AI stops being busy — enough to outlast speaker
    // playback latency and the room's audio decay.
    internal var micGatedUntilUptime: TimeInterval = 0

    // KV-cache persistence: set true once per session after the first
    // successful warmup persists the prefilled state to disk. Avoids
    // hammering the flash chip with redundant writes (warmup runs on
    // every VAD voice-start). Cleared when the engine unloads.
    internal var kvCachePersistedThisSession = false

    // TTS completion tracking — main thread only.
    internal var pendingTTSBuffers: Int = 0
    internal var ttsGenerationDone: Bool = false
    internal var pendingUIActionTask: Task<Void, Never>?
    /// Counts engine.speak(...) calls that haven't returned yet. The wait
    /// loop in `schedulePendingUIActionAfterSpeech` needs this in addition to
    /// `pendingTTSBuffers` so it doesn't fire while synthesis is still in
    /// flight but no buffers have been emitted yet.
    internal var inFlightSynthesis: Int = 0

    override init() {
        super.init()
        llmEngine.delegate = self
        whisperManager.delegate = self
        sileroVAD.delegate = self
        setupAudioEngine()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange, object: audioEngine)
    }

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeVal)
        else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            if !audioEngine.isRunning { try? audioEngine.start() }
        }
    }

    @objc private func handleEngineConfigChange() {
        guard !audioEngine.isRunning else { return }
        try? audioEngine.start()
    }

    /// Kicks off model loading at app launch.
    func preload() {
        Task {
            try? await llmEngine.loadModel()
            _ = await whisperManager.setup()
            // KV-cache restore from disk: if a previous session persisted
            // the prefilled persona/history prefix, load it back into the
            // bridge so the very first warmup hits 100% prefix-reuse and
            // cold-turn ttft drops from ~17 s to <1 s.
            await tryRestoreKVCache()
            // Cold-start warmup: prefill the persona/history prefix once
            // the engine is up so the first user turn doesn't pay the full
            // ~17 s ttft that an empty KV cache costs on iPhone 11.
            warmupPrefill()
        }
    }

    func startListening() {
        guard
            stateLock.withLock({
                if isPreparingOrActive { return false }
                isPreparingOrActive = true
                return true
            })
        else {
            nlLog("[LocalAI]: Already listening or preparing, skipping.", level: .info)
            return
        }

        Task {
            // Re-evaluate engine choice in case the model was downloaded since launch
            self.llmEngine = Self.makeEngine()
            self.llmEngine.delegate = self

            // Fast path: models already hot from preload() — start VAD with no delay.
            if llmEngine.isLoaded {
                await MainActor.run { state.status = .ready }
                sileroVAD.start(externalSampleRate: hardwareInputFormat?.sampleRate)
                return
            }

            await MainActor.run { state.status = .preparing }

            // LLM first, Whisper second: on 4 GB devices (iPhone 11/12/13)
            // WhisperKit reserves enough GPU/ANE memory to push llama.cpp's
            // Metal compile over the jetsam edge. Loading the LLM first means
            // it gets the full ~2.7 GB jetsam budget for Metal kernel
            // compilation; Whisper's CoreML model fits comfortably afterwards.
            do {
                try await llmEngine.loadModel()
            } catch {
                nlLog("[LocalLLM] Error loading model: \(error)", level: .info)
                stateLock.withLock { isPreparingOrActive = false }
                state.setError("Failed to initialize Local LLM (\(error.localizedDescription)).")
                return
            }

            let success = await whisperManager.setup()

            if success {
                await MainActor.run { state.status = .ready }
                sileroVAD.start(externalSampleRate: hardwareInputFormat?.sampleRate)
            } else {
                stateLock.withLock { isPreparingOrActive = false }
                state.setError("Failed to initialize WhisperKit.")
            }
        }
    }

    /// Receives transcribed text from the user, updates UI, and triggers the local LLM with RAG context.
    func handleUserInput(_ text: String) {
        turnStartNs = DispatchTime.now().uptimeNanoseconds
        firstTokenLatencyLogged = false
        firstAudioLatencyLogged = false

        Task { @MainActor in
            state.userTranscript = text
            state.aiTranscript = ""
            state.status = .thinking
        }

        ProactiveVisionManager.shared.notifyUserSpoke()
        ChatTimelineStore.logUserMessage(text)

        Task {
            let mgr = LocalModelDownloadManager.shared
            let isQwenFamily: Set<LocalModelDownloadManager.ModelConfiguration> = [
                .qwen2b, .qwen3b, .qwen7b
            ]
            let useQwen = mgr.isAvailable && isQwenFamily.contains(mgr.selectedConfig)
            let isJapaneseLlama = mgr.selectedConfig == .japaneseLlama1b

            // Build the 3-tier prompt via LocalLLMMemoryHierarchy:
            //   Tier 1: system + persona + (English-only: user context + companion)
            //   Tier 3: relevant facts from RAG (English-only)
            //   Tier 2: verbatim recent dialogue turns (English-only)
            //   + user turn, then budget-evict oldest pairs if needed.
            let basePrompt = localLLMSystemPrompt(for: state.selectedCharacterName)
            let messages = await LocalLLMMemoryHierarchy.shared.buildMessages(
                userInput: text,
                config: mgr.selectedConfig,
                characterName: state.selectedCharacterName,
                baseSystemPrompt: basePrompt
            )

            // Engine formats via the model's own GGUF chat template; falls
            // back to a hand-rolled template if the model has none.
            let prompt =
                llmEngine.applyChatTemplate(messages: messages)
                ?? fallbackChatPrompt(messages: messages, useQwen: useQwen)

            // Token caps tuned to local TTS speech rate, not raw quality:
            //   - Llama-1B on iPhone 11 decodes at ~4 tok/s. 60 tokens =
            //     ~15 s of speech, the realistic upper bound for a single
            //     spoken reply before the user disengages. The system
            //     prompt asks for 1–2 sentences anyway; cap matches intent.
            //   - JP path stays at 60 (no change — already tight).
            //   - Qwen tiers keep a longer budget since they're on devices
            //     where decode tok/s isn't the constraint.
            let maxTokens: Int = useQwen ? 160 : (isJapaneseLlama ? 60 : 60)

            await llmEngine.generate(prompt: prompt, maxTokens: maxTokens)
        }
    }

    /// Kicks off a background KV-cache warmup using the prompt-without-user-turn.
    /// Safe to call any time the engine is loaded and idle — the engine's
    /// prefill implementation `try()`s its lock and steps aside on contention.
    /// Returns immediately; the warmup runs on a utility-QoS queue.
    func warmupPrefill() {
        guard llmEngine.isLoaded else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let mgr = LocalModelDownloadManager.shared
            guard mgr.isAvailable else { return }
            let characterName = await MainActor.run { self.state.selectedCharacterName }
            let basePrompt = self.localLLMSystemPrompt(for: characterName)
            let messages = await LocalLLMMemoryHierarchy.shared.buildPrefillMessages(
                config: mgr.selectedConfig,
                characterName: characterName,
                baseSystemPrompt: basePrompt
            )
            await self.llmEngine.prefill(messages: messages)
            // Persist once per session — flash writes are slow on iPhone 11,
            // and the cache contents are essentially identical across the
            // warmups of a single session (persona/history is stable).
            await self.persistKVCacheIfNeeded(
                config: mgr.selectedConfig, systemPrompt: basePrompt)
        }
    }

    /// Try to load a previously-persisted KV cache state. Idempotent and
    /// safe to call multiple times — `loadKVCache` no-ops if the file is
    /// missing. Must run after `loadModel` and before any prefill/generate.
    ///
    /// Refuses to load any blob whose HMAC-SHA256 sidecar is
    /// missing, unreadable, or doesn't match. A failed verification
    /// purges the .kv + .kv.hmac files so the next launch starts clean
    /// — cold prefill costs ~17 s on iPhone 11 but is correct, vs. the
    /// alternative of feeding a tampered blob into the engine.
    private func tryRestoreKVCache() async {
        guard llmEngine.isLoaded else { return }
        let mgr = LocalModelDownloadManager.shared
        guard mgr.isAvailable else { return }
        let characterName = await MainActor.run { self.state.selectedCharacterName }
        let basePrompt = localLLMSystemPrompt(for: characterName)
        guard
            let path = LocalLLMKVCache.path(
                config: mgr.selectedConfig, systemPrompt: basePrompt)
        else { return }

        // No file at all = nothing to verify and nothing to purge —
        // fresh install / first-ever launch with this persona.
        guard FileManager.default.fileExists(atPath: path) else { return }

        guard LocalLLMKVCache.verifyIntegrity(at: path) else {
            nlLog(
                "[LocalLLMManager] KV cache integrity check failed; purging and falling back to cold prefill",
                level: .warning)
            LocalLLMKVCache.purge(at: path)
            return
        }

        let restored = await llmEngine.loadKVCache(from: path)
        if restored > 0 {
            // If we restored from disk, treat the cache as already
            // persisted — no need to rewrite the same bytes.
            kvCachePersistedThisSession = true
        }
    }

    /// Persist the current KV state to disk once per session. The cache
    /// key includes a hash of the system prompt so persona edits invalidate
    /// it automatically (new key → restore attempt misses → fresh prefill).
    private func persistKVCacheIfNeeded(
        config: LocalModelDownloadManager.ModelConfiguration,
        systemPrompt: String
    ) async {
        if kvCachePersistedThisSession { return }
        guard
            let path = LocalLLMKVCache.path(
                config: config, systemPrompt: systemPrompt)
        else { return }
        let saved = await llmEngine.saveKVCache(to: path)
        if saved {
            // Sign immediately after a successful save so the
            // next launch's `tryRestoreKVCache` can verify the bytes
            // weren't tampered with while the app was backgrounded.
            LocalLLMKVCache.signIntegrity(at: path)
            kvCachePersistedThisSession = true
        }
    }

    /// Hand-rolled chat template used when the model's GGUF has no embedded
    /// template (rare but possible with community quants). Llama-3 and ChatML
    /// formats cover every model we ship today.
    private func fallbackChatPrompt(messages: [LLMChatMessage], useQwen: Bool) -> String {
        if useQwen {
            var s = ""
            for m in messages {
                s += "<|im_start|>\(m.role)\n\(m.content)<|im_end|>\n"
            }
            s += "<|im_start|>assistant\n"
            return s
        }
        var s = ""
        for m in messages {
            s += "<|start_header_id|>\(m.role)<|end_header_id|>\n\n\(m.content)<|eot_id|>"
        }
        s += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return s
    }

    func stop() {
        sileroVAD.stop()
        llmEngine.stop()
        playerNode.stop()
        ttsBuffer = ""
        tagBuffer = ""
        pendingUIActionTask?.cancel()
        pendingUIActionTask = nil
        Task { @MainActor in
            pendingTTSBuffers = 0
            ttsGenerationDone = false
            inFlightSynthesis = 0
            state.status = .ready
        }
    }

    func restart() {
        stateLock.withLock { isPreparingOrActive = false }
        sileroVAD.stop()
        llmEngine.stop()
        playerNode.stop()
        ttsBuffer = ""
        tagBuffer = ""
        pendingUIActionTask?.cancel()
        pendingUIActionTask = nil
        recordingLock.lock()
        isRecordingVoice = false
        recordingBuffer.removeAll()
        recordingLock.unlock()
        Task { @MainActor in
            pendingTTSBuffers = 0
            ttsGenerationDone = false
            inFlightSynthesis = 0
            state.status = .disconnected
            startListening()
        }
    }

    func unload() {
        stateLock.withLock { isPreparingOrActive = false }
        sileroVAD.stop()
        llmEngine.stop()
        llmEngine.unloadModel()
        // New engine session next time — let the first successful warmup
        // re-persist the cache.
        kvCachePersistedThisSession = false
        playerNode.stop()
        ttsBuffer = ""
        tagBuffer = ""
        pendingUIActionTask?.cancel()
        pendingUIActionTask = nil
        recordingLock.lock()
        recordingBuffer.removeAll()
        isRecordingVoice = false
        recordingLock.unlock()
        Task { @MainActor in
            pendingTTSBuffers = 0
            ttsGenerationDone = false
            inFlightSynthesis = 0
            state.status = .disconnected
        }
        nlLog("[LocalLLM] Manager unloaded — all models freed.", level: .info)
    }

    // MARK: - Local TTS (AVSpeechSynthesizer + AVAudioEngine)

    /// Handles a physical interaction event (e.g. head pat) by triggering the local LLM.
    func handleInteractionEvent(_ action: String) {
        // We reuse handleUserInput but we might want to wrap the action in a way
        // that the model understands it's a physical action, not spoken text.
        let text = "*\(action)*"
        handleUserInput(text)
    }

    @MainActor
    func schedulePendingUIActionAfterSpeech() {
        pendingUIActionTask?.cancel()
        pendingUIActionTask = Task { [weak self] in
            guard let self else { return }
            // Wait until the queued TTS buffers drain and no engine.speak() is in flight.
            while !Task.isCancelled {
                if self.pendingTTSBuffers <= 0 && self.inFlightSynthesis == 0 {
                    break
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }
            let action = AppFunctionExecutor.shared.pendingUIAction
            AppFunctionExecutor.shared.pendingUIAction = nil
            action?()
        }
    }
}
