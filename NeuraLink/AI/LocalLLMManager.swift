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
    private let synthesizer = AVSpeechSynthesizer()

    // State
    let state = RealtimeChatState.shared
    var llmEngine: any LLMEngineProtocol = LocalLLMManager.makeEngine()

    let whisperManager = LocalWhisperManager.shared
    internal let sileroVAD = SileroVADProcessor()

    // Accumulate text for TTS chunking (e.g., speak sentence by sentence)
    var ttsBuffer = ""

    // Audio Capture State
    var hardwareInputFormat: AVAudioFormat?
    var recordingBuffer = [Float]()
    var isRecordingVoice = false
    let recordingLock = NSLock()

    // Lightweight turn-level latency metrics (user text → token/audio)
    private var turnStartNs: UInt64?
    private var firstTokenLatencyLogged = false
    private var firstAudioLatencyLogged = false

    // TTS completion tracking — main thread only.
    private var pendingTTSBuffers: Int = 0
    private var ttsGenerationDone: Bool = false

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

        Task {
            // RAG: Fetch relevant past memories
            let memoryContext = await RAGManager.shared.fetchContext(for: text)
            
            let basePrompt = localLLMSystemPrompt(for: state.selectedCharacterName)
            let sysPrompt = basePrompt + memoryContext
            
            let prompt: String
            let maxTokens: Int
            let mgr = LocalModelDownloadManager.shared
            let useQwen = mgr.isAvailable && mgr.selectedConfig == .qwen2b

            if useQwen {
                prompt = "<|im_start|>system\n\(sysPrompt)<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
                maxTokens = 160
            } else {
                prompt = "<|start_header_id|>system<|end_header_id|>\n\n\(sysPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(text)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
                maxTokens = 100
            }

            await llmEngine.generate(prompt: prompt, maxTokens: maxTokens)
        }
    }

    func stop() {
        sileroVAD.stop()
        llmEngine.stop()
        playerNode.stop()
        ttsBuffer = ""
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

    private func speakChunk(_ text: String) {
        if !firstAudioLatencyLogged,
            let start = turnStartNs,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstAudioLatencyLogged = true
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("[LocalLLM] First TTS chunk latency: \(String(format: "%.1f", elapsedMs)) ms")
        }
        
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.replacingOccurrences(of: #"\*[^*\n]+\*"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"\[[^\]\n]+\]"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty,
              clean.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
        else { return }

        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = bestAvailableVoice(for: state.selectedCharacterName)

        if clean.hasSuffix("?") || clean.hasSuffix("？") {
            utterance.pitchMultiplier = 1.1
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        } else if clean.hasSuffix("!") || clean.hasSuffix("！") {
            utterance.pitchMultiplier = 1.05
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate + 0.03
        } else {
            utterance.pitchMultiplier = 1.0
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        }

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self = self, let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            guard pcmBuffer.frameLength > 0 else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let currentFormat = self.playerNode.outputFormat(forBus: 0)
                if currentFormat != pcmBuffer.format {
                    let wasRunning = self.audioEngine.isRunning
                    if wasRunning { self.audioEngine.pause() }

                    self.audioEngine.disconnectNodeInput(self.playerNode)
                    self.audioEngine.connect(
                        self.playerNode, to: self.audioEngine.mainMixerNode, format: pcmBuffer.format)

                    if wasRunning { try? self.audioEngine.start() }
                }

                if !self.audioEngine.isRunning { try? self.audioEngine.start() }
                if !self.playerNode.isPlaying { self.playerNode.play() }

                self.pendingTTSBuffers += 1
                self.playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataConsumed) {
                    [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.pendingTTSBuffers -= 1
                        if self.pendingTTSBuffers == 0 && self.ttsGenerationDone {
                            self.ttsGenerationDone = false
                            self.state.status = .ready
                        }
                    }
                }
            }
        }
    }
}

// MARK: - LocalLLMEngineDelegate

extension LocalLLMManager: LocalLLMEngineDelegate {
    func localLLM(didGenerateToken token: String) {
        if !firstTokenLatencyLogged,
            let start = turnStartNs,
            !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstTokenLatencyLogged = true
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("[LocalLLM] First token latency: \(String(format: "%.1f", elapsedMs)) ms")
        }

        Task { @MainActor in
            if state.status == .thinking {
                state.status = .speaking
            }
            state.aiTranscript += token
            state.parseAndTriggerEmotion(from: state.aiTranscript)
        }

        ttsBuffer += token

        let openBrackets  = ttsBuffer.filter { $0 == "[" }.count
        let closeBrackets = ttsBuffer.filter { $0 == "]" }.count
        let insideTag = openBrackets > closeBrackets

        if !insideTag
            && (token.contains(".") || token.contains("!") || token.contains("?")
                || token.contains("。") || token.contains(",") || token.contains("\n")
                || (ttsBuffer.count >= 32 && ttsBuffer.contains(" "))) {
            let chunkToSpeak = ttsBuffer
            ttsBuffer = ""
            speakChunk(chunkToSpeak)
        }
    }

    func localLLM(didFinishGeneration fullText: String) {
        if let start = turnStartNs {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("[LocalLLM] Turn total latency: \(String(format: "%.1f", elapsedMs)) ms")
        }

        // RAG: Store the user's input and the AI's response in long-term memory
        let userText = state.userTranscript
        RAGManager.shared.store(text: userText)
        RAGManager.shared.store(text: fullText)

        if !ttsBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            speakChunk(ttsBuffer)
            ttsBuffer = ""
        }
        Task { @MainActor in
            if pendingTTSBuffers == 0 {
                state.status = .ready
            } else {
                ttsGenerationDone = true
            }
        }
    }

    func localLLM(didFailWithError error: Error) {
        Task { @MainActor in
            state.setError(error.localizedDescription)
        }
    }
}
