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
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()

    // State
    let state = RealtimeChatState.shared
    var llmEngine: any LLMEngineProtocol = LocalLLMManager.makeEngine()

    let whisperManager = LocalWhisperManager.shared
    private let sileroVAD = SileroVADProcessor()

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
    // State stays .speaking until all scheduled PCM buffers have actually played out, which prevents VAD from picking up speaker output and triggering a self-reply.
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
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try? engine.start() }
        }
    }

    @objc private func handleEngineConfigChange() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    /// Kicks off model loading at app launch. LLM loads first so loadTask is establish before startListening() can race it; then WhisperKit initializes in the same Task.
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

    private func setupAudioEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .default gives full microphone gain at desk/arm-length distances.
            // .voiceChat is tuned for a phone held to the ear and reduces mic gain 5-15×
            // at normal speaking distances, producing amplitudes too low for Whisper.
            // .allowBluetoothA2DP keeps AirPods for TTS output without routing the
            // microphone through the low-quality Bluetooth SCO channel.
            try session.setCategory(
                .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)

            // Explicitly pin to the built-in mic so connecting AirPods later doesn't
            // silently reroute the input to the Bluetooth device's low-quality mic.
            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }
            ) {
                try? session.setPreferredInput(builtInMic)
            }
        } catch {
            print("[LocalAI]: Failed to configure audio session: \(error)")
        }

        // Standard iOS TTS is 22050 Hz or 24000 Hz depending on the voice,
        // but AVSpeechSynthesizer.write usually outputs 22050 Hz Float32.
        // We will configure the format dynamically when the first buffer arrives,
        // but attach the node now.
        engine.attach(playerNode)
        // AVSpeechSynthesizer write() outputs at ~0.3-0.4 RMS; boosting to 2.5×
        // brings it closer to the perceived loudness of the OpenAI WebRTC path.
        playerNode.volume = 2.5

        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)

        // Tap the main mixer to provide amplitude data for Lip-Sync
        let mixFmt = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixFmt) {
            [weak self] buffer, _ in
            self?.reportAmplitude(buffer)
        }

        // Set up Microphone Capture Tap
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        self.hardwareInputFormat = inputFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            self?.processCapturedAudio(buffer: buffer)
        }

        do {
            try engine.start()
            print("[LocalAI]: AVAudioEngine started for local TTS & Input Capture.")
        } catch {
            print("[LocalAI]: Failed to start audio engine: \(error)")
        }
    }

    /// Receives transcribed text from the user, updates UI, and triggers the local LLM.
    func handleUserInput(_ text: String) {
        turnStartNs = DispatchTime.now().uptimeNanoseconds
        firstTokenLatencyLogged = false
        firstAudioLatencyLogged = false

        Task { @MainActor in
            state.userTranscript = text
            state.aiTranscript = ""
            state.status = .thinking
        }

        // Local LLMs get a stripped-down spoken-word prompt.
        // The full CharacterPersona.instructions are written for OpenAI and encourage elaborate roleplay prose (*actions*, emotional narration) that small model reproduce verbatim — making them sound like a light novel read aloud.
        // This prompt captures just enough character flavour for a 1-2B model.
        let sysPrompt = localLLMSystemPrompt(for: state.selectedCharacterName)
        let prompt: String
        let maxTokens: Int
        let mgr = LocalModelDownloadManager.shared
        let useQwen = mgr.isAvailable && mgr.selectedConfig == .qwen2b

        if useQwen {
            prompt = "<|im_start|>system\n\(sysPrompt)<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
            maxTokens = 160
        } else {
            // Omit <|begin_of_text|> — llama.cpp adds BOS automatically; including it doubles the BOS token.
            prompt = "<|start_header_id|>system<|end_header_id|>\n\n\(sysPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(text)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
            maxTokens = 100
        }

        Task {
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

    /// Stops the current session and immediately starts a fresh one.
    /// Used when the user switches the local LLM model mid-session.
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

    /// Stops all activity and releases the LLM + Whisper models from memory.
    /// Called when the user disables Local SLM in settings.
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
            print(
                "[LocalLLM] First TTS chunk latency: \(String(format: "%.1f", elapsedMs)) ms"
            )
        }
        
        // Strip light-novel roleplay markers/tags before TTS — the synthesizer reads them literally (*big hug* becomes "asterisk big hug asterisk"), which sounds terrible.
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

        // Vary pitch and rate per sentence type so TTS doesn't sound monotone.
        // Questions rise, exclamations are slightly punchy, statements are calm.
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

        // Use the write() API to intercept audio buffers instead of playing directly.
        // This allows us to route it through AVAudioEngine to measure amplitude for lip-sync.
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self = self, let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

            // Bail BEFORE any engine manipulation to avoid the zero-byte AVAudioBuffer crash.
            guard pcmBuffer.frameLength > 0 else { return }

            // Engine reconnection must run on the main thread to prevent the
            // "unsafeForcedSync called from Swift Concurrent context" deadlock.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // AVSpeechSynthesizer can change formats depending on the voice.
                // Reconnect the node if the format differs from what we initialized.
                let currentFormat = self.playerNode.outputFormat(forBus: 0)
                if currentFormat != pcmBuffer.format {
                    let wasRunning = self.engine.isRunning
                    if wasRunning { self.engine.pause() }

                    self.engine.disconnectNodeInput(self.playerNode)
                    self.engine.connect(
                        self.playerNode, to: self.engine.mainMixerNode, format: pcmBuffer.format)

                    if wasRunning { try? self.engine.start() }
                }

                if !self.engine.isRunning {
                    try? self.engine.start()
                }

                if !self.playerNode.isPlaying {
                    self.playerNode.play()
                }

                // Track this buffer so state stays .speaking until the hardware
                // finishes playing it — prevents VAD self-trigger from speaker output.
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

    private func reportAmplitude(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let length = Int(buffer.frameLength)
        guard length > 0 else { return }

        var sum: Float = 0
        for i in 0..<length {
            sum += channelData[0][i] * channelData[0][i]
        }
        let rms = sqrt(sum / Float(length))

        Task { @MainActor in
            // Multiply by 5.0 to exaggerate the lip-sync slightly for TTS
            self.state.audioLevel = min(rms * 5.0, 1.0)
        }
    }

    private func processCapturedAudio(buffer: AVAudioPCMBuffer) {
        // Feed the audio directly to Silero to avoid audio engine collision
        sileroVAD.processAudioBuffer(buffer)

        recordingLock.lock()
        defer { recordingLock.unlock() }

        if let channelData = buffer.floatChannelData {
            let length = Int(buffer.frameLength)
            let pointer = channelData[0]
            let floatArray = Array(UnsafeBufferPointer(start: pointer, count: length))
            recordingBuffer.append(contentsOf: floatArray)

            // If not recording, maintain a rolling pre-roll buffer (0.5 seconds)
            // to capture the audio that triggered the VAD.
            if !isRecordingVoice {
                let maxPreRoll = Int((hardwareInputFormat?.sampleRate ?? 48000.0) * 0.5)
                if recordingBuffer.count > maxPreRoll {
                    recordingBuffer.removeFirst(recordingBuffer.count - maxPreRoll)
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
            print(
                "[LocalLLM] First token latency: \(String(format: "%.1f", elapsedMs)) ms"
            )
        }

        Task { @MainActor in
            if state.status == .thinking {
                state.status = .speaking
            }
            state.aiTranscript += token
            state.parseAndTriggerEmotion(from: state.aiTranscript)
        }

        // Buffer tokens. When we hit a punctuation mark, synthesize speech.
        ttsBuffer += token

        // Never flush mid-tag: a decimal duration like [happy:1.5] contains a period
        // that would otherwise split the tag across chunks, breaking the strip regex.
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
        print("[LocalLLM] Full response: \(fullText)")

        // Flush any remaining text in the buffer
        if !ttsBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            speakChunk(ttsBuffer)
            ttsBuffer = ""
        }
        Task { @MainActor in
            // Only return to .ready once the last PCM buffer has actually played out.
            // If there are pending buffers, mark done and let the completion handler fire .ready
            // when hardware drains the last frame — this prevents VAD from picking up speaker output.
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
