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
        }
    }

    // Audio Engine for TTS Lip-sync
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var ttsEngine: any TTSProtocol = F5TTSEngine()

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

    override init() {
        super.init()
        llmEngine.delegate = self
        whisperManager.delegate = self
        sileroVAD.delegate = self
        setupAudioEngine()
        setupTTSEngine()
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
        switch type {
        case .began:
            // Stop the player cleanly so the engine queue isn't left in a torn state.
            // Font-service / phone-call interruptions hit this path.
            playerNode.stop()
            engine.pause()
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try? engine.start() }
            playerNode.play()
        @unknown default:
            break
        }
    }

    @objc private func handleEngineConfigChange() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    /// Kicks off model loading at app launch. LLM loads first so loadTask is established
    /// before startListening() can race it; then WhisperKit initializes in the same Task.
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

    private func setupTTSEngine() {
        ttsEngine.onBufferReady = { [weak self] pcmBuffer in
            guard let self = self else { return }

            // Engine reconnection must run on the main thread to prevent the
            // "unsafeForcedSync called from Swift Concurrent context" deadlock.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // AVSpeechSynthesizer.write() sends a zero-frame "completion" buffer
                // to signal end of utterance. Scheduling it causes AVAudioPlayerNode
                // to log "mDataByteSize (0) should be non-zero" and may corrupt the
                // player's internal queue — drop it before touching the engine.
                guard pcmBuffer.frameLength > 0 else { return }

                // LLM and Whisper were unloaded before F5-TTS synthesis to keep
                // total Metal usage under the 2098 MB jetsam ceiling. Reload both
                // now — speech playback takes ~2-5 s, giving them time to finish
                // loading before the user's next turn.
                if !self.llmEngine.isLoaded {
                    Task { [weak self] in try? await self?.llmEngine.loadModel() }
                }
                if !self.whisperManager.isReadyToUse {
                    Task { [weak self] in await self?.whisperManager.setup() }
                }

                // Reconnect the node only if the format changed AND is valid.
                // engine.connect raises an NSException for formats with sampleRate=0.
                let currentFormat = self.playerNode.outputFormat(forBus: 0)
                let newFormat = pcmBuffer.format
                if currentFormat != newFormat,
                   newFormat.sampleRate > 0, newFormat.channelCount > 0 {
                    let wasRunning = self.engine.isRunning
                    if wasRunning { self.engine.pause() }

                    self.engine.disconnectNodeInput(self.playerNode)
                    self.engine.connect(
                        self.playerNode, to: self.engine.mainMixerNode, format: newFormat)

                    if wasRunning { try? self.engine.start() }
                }

                if !self.engine.isRunning {
                    try? self.engine.start()
                }

                if !self.playerNode.isPlaying {
                    self.playerNode.play()
                }

                self.playerNode.scheduleBuffer(pcmBuffer)
            }
        }
    }

    /// Receives transcribed text from the user, updates UI, and triggers the local LLM.
    func handleUserInput(_ text: String) {
        // Cancel any in-flight generation and speech so a new user turn always
        // starts clean. Without this, a second VAD trigger during LLM generation
        // starts a concurrent generate() on the same llama.cpp context → crash.
        llmEngine.stop()
        ttsEngine.stop()
        playerNode.stop()
        ttsBuffer = ""

        turnStartNs = DispatchTime.now().uptimeNanoseconds
        firstTokenLatencyLogged = false
        firstAudioLatencyLogged = false

        Task { @MainActor in
            state.userTranscript = text
            state.aiTranscript = ""
            state.status = .thinking
        }

        let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)
        let prompt: String
        let maxTokens: Int
        let mgr = LocalModelDownloadManager.shared
        let useQwen = mgr.isAvailable && mgr.selectedConfig == .qwen2b

        if useQwen {
            // Qwen instruct template
            prompt = "<|im_start|>system\n\(persona.instructions)<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
            maxTokens = 128
        } else {
            // Llama-3 on Metal GPU: prefill scales with prompt token count.
            // A 100-token system prompt alone costs ~25 s on A13.
            // 30-char system tag ≈ 6 tokens; 40-char user ≈ 8 tokens → ~14 token prefill.
            // Omit <|begin_of_text|>: llama.cpp adds BOS during tokenisation;
            // including it manually produces a double-BOS that corrupts positional
            // embeddings and causes the model to hallucinate multi-turn conversations.
            let brief = String(persona.instructions.prefix(30))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let shortText = String(text.prefix(40))
            prompt = "<|start_header_id|>system<|end_header_id|>\n\n\(brief)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(shortText)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
            maxTokens = 64
        }

        Task {
            await llmEngine.generate(prompt: prompt, maxTokens: maxTokens)
        }
    }

    func stop() {
        sileroVAD.stop()
        llmEngine.stop()
        ttsEngine.stop()
        playerNode.stop()
        ttsBuffer = ""
        Task { @MainActor in
            state.status = .ready
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

        // F5-TTS ODE peaks at ~400 MB of Metal activations. Even with the LLM unloaded,
        // DiT (650 MB) + Vocos (50 MB) + Whisper (150 MB) + activations (400 MB) + Metal
        // shader compiler service (~300 MB, separate pid) = ~1550 MB — enough to jetsam
        // the compiler. Also unload Whisper here; F5-TTS runs in Task.detached so the
        // user can't speak during synthesis anyway. Both models reload in onBufferReady.
        if (ttsEngine as? F5TTSEngine)?.isReady == true {
            print("[LocalLLM] F5-TTS ready — unloading LLM + Whisper to free Metal memory")
            llmEngine.unloadModel()
            whisperManager.unload()
        }

        ttsEngine.speak(text, for: state.selectedCharacterName)
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
        }

        // Accumulate tokens; speak the complete response on didFinishGeneration
        // for natural, non-chunked speech.
        ttsBuffer += token
    }

    func localLLM(didFinishGeneration fullText: String) {
        if let start = turnStartNs {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            print("[LocalLLM] Turn total latency: \(String(format: "%.1f", elapsedMs)) ms")
        }

        // Speak the complete response as one utterance for natural prosody.
        let textToSpeak = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !textToSpeak.isEmpty {
            speakChunk(textToSpeak)
        }
        ttsBuffer = ""
        Task { @MainActor in
            state.status = .ready
        }
    }

    func localLLM(didFailWithError error: Error) {
        Task { @MainActor in
            state.setError(error.localizedDescription)
        }
    }
}
