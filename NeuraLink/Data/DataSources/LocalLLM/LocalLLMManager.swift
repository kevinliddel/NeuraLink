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
        case .llama1b:
            return GGUFLlamaEngine.shared
        case .japaneseLlama1b:
            return GGUFJapaneseLlamaEngine.shared
        }
    }

    // Audio Engine for TTS Lip-sync
    internal let audioEngine = AVAudioEngine()
    internal let playerNode = AVAudioPlayerNode()
    internal let synthesizer = AVSpeechSynthesizer()

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
    
    // Partial transcription state
    internal var isTranscribingPartial = false
    internal var lastPartialTranscribedCount = 0

    // Lightweight turn-level latency metrics (user text → token/audio)
    internal var turnStartNs: UInt64?
    internal var firstTokenLatencyLogged = false
    internal var firstAudioLatencyLogged = false

    // TTS completion tracking — main thread only.
    internal var pendingTTSBuffers: Int = 0
    internal var ttsGenerationDone: Bool = false
    internal var pendingUIActionTask: Task<Void, Never>?

    var voicesLogged = false

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
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
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
        }
    }

    func startListening() {
        // Prevent redundant start attempts if already active or preparing.
        guard state.status != .preparing && state.status != .ready && state.status != .listening && 
              state.status != .thinking && state.status != .speaking else {
            print("[LocalAI]: Already listening or preparing, skipping.")
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
            let success = await whisperManager.setup()

            do {
                try await llmEngine.loadModel()
            } catch {
                print("[LocalLLM] Error loading model: \(error)")
                state.setError("Failed to initialize Core ML LLM.")
                return
            }

            if success {
                await MainActor.run { state.status = .ready }
                sileroVAD.start(externalSampleRate: hardwareInputFormat?.sampleRate)
            } else {
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
            let useQwen = mgr.isAvailable && mgr.selectedConfig == .qwen2b
            let isJapaneseLlama = mgr.selectedConfig == .japaneseLlama1b

            // For the Japanese 1B model: skip RAG and extra context entirely.
            // Stored memories are in English/mixed language and inflate prompt size,
            // causing latency growth and language confusion in a small model.
            let truncatedMemory: String
            let userContext: String
            let companion: String
            if isJapaneseLlama {
                truncatedMemory = ""
                userContext = ""
                companion = ""
            } else {
                let raw = await RAGManager.shared.fetchContext(for: text)
                truncatedMemory = String(raw.prefix(500))
                userContext = UserSettings.shared.systemPromptContext
                companion = CompanionStateManager.shared.promptContext(characterName: state.selectedCharacterName)
            }

            let basePrompt = localLLMSystemPrompt(for: state.selectedCharacterName)
            var sysPrompt: String
            if isJapaneseLlama {
                // Put language instruction first — a 1B model attends most to early tokens.
                sysPrompt = "必ず日本語で返答してください。\n" + basePrompt
            } else {
                sysPrompt = basePrompt + userContext + truncatedMemory + companion
            }

            // No history for the Japanese 1B model: with limit: 2 the dedup logic produces
            // an orphaned AI response (no preceding user turn), which makes the model repeat
            // itself. A 1B model also can't use history coherently — it just inflates the
            // prompt and causes O(N) latency growth without improving response quality.
            let historyLimit = isJapaneseLlama ? 0 : 6
            var recentEvents = Array(MemoryStore.shared.fetchChatEvents(limit: historyLimit).reversed())
            if let last = recentEvents.last, last.role == "user", last.detail == text {
                recentEvents.removeLast()
            }

            var prompt: String
            let maxTokens: Int

            if useQwen {
                prompt = "<|im_start|>system\n\(sysPrompt)<|im_end|>\n"
                var history = ""
                for event in recentEvents {
                    let role = event.role == "ai" ? "assistant" : "user"
                    history += "<|im_start|>\(role)\n\(event.detail)<|im_end|>\n"
                }
                prompt += history + "<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
                maxTokens = 160
            } else {
                prompt = "<|start_header_id|>system<|end_header_id|>\n\n\(sysPrompt)<|eot_id|>"
                var history = ""
                for event in recentEvents {
                    let role = event.role == "ai" ? "assistant" : "user"
                    history += "<|start_header_id|>\(role)<|end_header_id|>\n\n\(event.detail)<|eot_id|>"
                }
                // Inject a per-turn language reminder for the Japanese model: small models
                // respond more reliably to language instructions in the user turn.
                let userMessage = isJapaneseLlama ? "（日本語で回答）\(text)" : text
                prompt += history + "<|start_header_id|>user<|end_header_id|>\n\n\(userMessage)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
                // 60-token cap for Japanese: forces 1–2 sentence responses that match the
                // system prompt instruction, cuts generation time by ~40%, and reduces
                // the AI response tokens that would otherwise inflate future prompts.
                maxTokens = isJapaneseLlama ? 60 : 100
            }

            await llmEngine.generate(prompt: prompt, maxTokens: maxTokens)
        }
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
            state.status = .ready
        }
    }

    func restart() {
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
            state.status = .disconnected
            startListening()
        }
    }

    func unload() {
        sileroVAD.stop()
        llmEngine.stop()
        llmEngine.unloadModel()
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
            state.status = .disconnected
        }
        print("[LocalLLM] Manager unloaded — all models freed.")
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
            // Wait until the queued TTS buffers drain and synthesizer finishes.
            while !Task.isCancelled {
                if self.pendingTTSBuffers <= 0 && !self.synthesizer.isSpeaking {
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
