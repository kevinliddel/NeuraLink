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
    // Llama-1B (English) is the memory-safe default; LLM-jp-3 is the JP slot.
    private static func makeEngine() -> any LLMEngineProtocol {
        let manager = LocalModelDownloadManager.shared
        guard manager.isAvailable else {
            // No model is ready yet; return GGUF engine as a safe placeholder.
            return GGUFLlamaEngine.shared
        }

        switch manager.selectedConfig {
        case .llama1b:
            return GGUFLlamaEngine.shared
        case .llmJp3:
            return GGUFLLMjp3Engine.shared
        }
    }

    // Audio Engine for TTS Lip-sync
    internal let audioEngine = AVAudioEngine()
    internal let playerNode = AVAudioPlayerNode()
    /// Fixed-rate (48 kHz) mixer between `playerNode` and the main mixer.
    /// TTS engines emit different sample rates (Kokoro/VoiceVox 24 kHz,
    /// System TTS locale-dependent); pinning this edge means a format change
    /// only rewires the local player → mixer connection instead of pausing
    /// the whole engine (which also interrupted mic capture). Also the
    /// attach point for a future second player for chunk crossfade.
    internal let ttsMixerNode = AVAudioMixerNode()

    // State
    let state = RealtimeChatState.shared
    var llmEngine: any LLMEngineProtocol = LocalLLMManager.makeEngine()

    /// Coalesces per-token transcript updates into a smooth ~33 fps reveal
    /// (Fix 2 typewriter + Fix 3 coalesce). Fed by `didGenerateToken`; drains
    /// onto `state.aiTranscript`.
    let transcriptTypewriter = TranscriptTypewriter()

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

    // TTS chunking: true until the first chunk of the current turn is emitted.
    // The first chunk flushes at the earliest clause boundary so audio starts
    // ASAP; later chunks prefer whole sentences for natural prosody. Reset per
    // turn in handleUserInput. See the chunker in LocalLLMManager+Engine.
    internal var firstTTSChunkPending = true

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
        transcriptTypewriter.bind(state)
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
                prewarmTTS()
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

            // Cold first-token fix: restore the persisted persona-prefix KV and
            // warm it up right after load, BEFORE Whisper setup so Whisper's
            // load overlaps the warm-up (a short forward pass reusing the
            // just-compiled kernels — no big new allocation). At launch this
            // runs long before the user's first utterance, so that turn reuses
            // the warm prefix and only prefills the short user-turn delta
            // (cold ttft ~5 s → <1 s). The VAD-voice-start `warmupPrefill()`
            // alone raced the utterance and usually lost; `preload()` had this
            // sequence but is never called — `startListening()` is the real
            // launch entry, so the warm-up has to live here.
            await tryRestoreKVCache()
            warmupPrefill()

            let success = await whisperManager.setup()

            if success {
                await MainActor.run { state.status = .ready }
                sileroVAD.start(externalSampleRate: hardwareInputFormat?.sampleRate)
                prewarmTTS()

                #if DEBUG
                // Memory A/B (`-nl.debug.skipWhisper YES`): `whisperManager.setup()`
                // no-oped above, so WhisperKit's CoreML/ANE memory is freed. Fire
                // one canned JP turn here — this is the *real* entry point (the
                // avatar is on-screen and rendering, VoiceVox pre-warm state is
                // identical to a normal turn), so the ONLY changed variable vs a
                // normal run is WhisperKit's footprint. Read the resulting
                // `[Bench]` decode=…tok/s: a big jump over the ~0.15 tok/s
                // baseline proves memory pressure is the bottleneck. Run from a
                // cold launch (the post-load path, not the fast path).
                if UserDefaults.standard.bool(forKey: "nl.debug.skipWhisper") {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    await MainActor.run {
                        self.handleUserInput("こんにちは、今日の調子はどう？", logToTimeline: false)
                    }
                }
                #endif
            } else {
                stateLock.withLock { isPreparingOrActive = false }
                state.setError("Failed to initialize speech recognition (whisper.cpp).")
            }
        }
    }

    /// Pre-warms the TTS engine for the current persona so its (potentially
    /// slow) first-run init — OpenVoice's model download + ONNX session load,
    /// VoiceVox's OpenJTalk load — overlaps listening + LLM generation instead
    /// of blocking the first spoken chunk. Idempotent: once the engine is
    /// ready, `initialize()` returns immediately. Fire-and-forget.
    func prewarmTTS() {
        Task { @MainActor in
            let persona = state.selectedCharacterName
            guard let engine = TTSEngineSelector.shared.engine(for: persona) else { return }
            do {
                try await engine.initialize()
                nlLog("[LocalLLM] TTS pre-warmed for '\(persona)'", level: .info)
            } catch {
                nlLog("[LocalLLM] TTS pre-warm failed for '\(persona)': \(error)", level: .warning)
            }
        }
    }

    /// Receives transcribed text from the user, updates UI, and triggers the local LLM with RAG context.
    /// - Parameter logToTimeline: whether to persist this turn as a user
    ///   message in the chat timeline. Real spoken/typed input logs; physical
    ///   interaction events (head pat etc.) pass `false` so they don't clutter
    ///   the timeline as if the user had said `*head pat*`.
    func handleUserInput(_ text: String, logToTimeline: Bool = true) {
        turnStartNs = DispatchTime.now().uptimeNanoseconds
        firstTokenLatencyLogged = false
        firstAudioLatencyLogged = false
        firstTTSChunkPending = true

        Task { @MainActor in
            state.userTranscript = text
            transcriptTypewriter.reset()   // clears the transcript + typewriter state
            state.status = .thinking
        }

        // 4 GB tier: free Whisper's resident model (~150 MB) for the decode
        // window so the LLM's mmap'd weights stay resident instead of streaming
        // from flash. STT for this turn is already done (we have `text`), and
        // VAD won't start a new listen until status returns to `.ready` — so
        // Whisper is reloaded in `didFinishGeneration`, well before the next
        // utterance. No-op on 6 GB+, where the model fits without this.
        if Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0 < 5.0 {
            whisperManager.shutdown()
        }

        ProactiveVisionManager.shared.notifyUserSpoke()
        // `logUserMessage` already drops empty/whitespace turns; the flag
        // additionally excludes physical-interaction actions.
        if logToTimeline {
            ChatTimelineStore.logUserMessage(text)
        }

        Task {
            let mgr = LocalModelDownloadManager.shared

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

            // Engine formats via the model's own GGUF chat template; falls back
            // to a hand-rolled Llama-3 template only if the model has none. The
            // JP slot (LLM-jp-3) embeds its own GGUF template, so the fallback is
            // a safety net for the Llama-1B path only.
            let prompt =
                llmEngine.applyChatTemplate(messages: messages)
                ?? fallbackChatPrompt(messages: messages)

            // Token cap tuned to local TTS speech rate, not raw quality: on
            // iPhone 11, 60 tokens ≈ 15 s of speech — the realistic upper bound
            // for a single spoken reply. The system prompt asks for 1–2
            // sentences anyway. Applies to both Llama-1B and the JP path.
            let maxTokens = 60

            await llmEngine.generate(prompt: prompt, maxTokens: maxTokens)
        }
    }

    /// Kicks off a background KV-cache warmup using the prompt-without-user-turn.
    /// Safe to call any time the engine is loaded and idle — the engine's
    /// prefill implementation `try()`s its lock and steps aside on contention.
    /// Returns immediately; the warmup runs on a utility-QoS queue.
    func warmupPrefill() {
        guard llmEngine.isLoaded else { return }
        // .userInitiated, not .utility: this warm-up is what stands between app
        // launch (or VAD voice-start) and a fast first token. The engine's
        // prefill uses bridgeLock.try() so it still yields to a real turn.
        Task.detached(priority: .userInitiated) { [weak self] in
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

    // KV-cache persistence methods live in LocalLLMManager+KVCache.swift
    // (split for SwiftLint 495-line compliance).

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
        // Don't log it to the timeline — it's an action, not something the user
        // said, so persisting `*head pat*` as a user message just adds noise.
        let text = "*\(action)*"
        handleUserInput(text, logToTimeline: false)
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
