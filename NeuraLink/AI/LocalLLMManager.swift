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

    // On iOS 18+ with ≥6 GB RAM: stateful Qwen3-VL 2B (KV cache, fast decode).
    // On iOS 18+ with <6 GB RAM (e.g. iPhone 11 / 4 GB): Qwen3-VL 2B needs ~3 GB at
    // runtime and will OOM — fall back to the stateless Llama-3.2-1B engine.
    // On iOS 17: always use the Llama-3.2-1B engine.
    private static func makeEngine() -> any LLMEngineProtocol {
        if #available(iOS 18.0, *) {
            let sixGB: UInt64 = 6 * 1024 * 1024 * 1024
            if ProcessInfo.processInfo.physicalMemory >= sixGB {
                return StatefulQwenEngine.shared as! LLMEngineProtocol
            }
        }
        return LocalLLMEngine.shared
    }

    // Audio Engine for TTS Lip-sync
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()

    // State
    private let state = RealtimeChatState.shared
    private let llmEngine: any LLMEngineProtocol = LocalLLMManager.makeEngine()

    private let whisperManager = LocalWhisperManager.shared
    private let sileroVAD = SileroVADProcessor()

    // Accumulate text for TTS chunking (e.g., speak sentence by sentence)
    private var ttsBuffer = ""

    // Audio Capture State
    private var hardwareInputFormat: AVAudioFormat?
    private var recordingBuffer = [Float]()
    private var isRecordingVoice = false
    private let recordingLock = NSLock()

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

    /// Kicks off model loading at app launch. LLM loads first so loadTask is established
    /// before startListening() can race it; then WhisperKit initializes in the same Task.
    func preload() {
        Task {
            try? await llmEngine.loadModel()
            _ = await whisperManager.setup()
        }
    }

    func startListening() {
        Task {
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
        Task { @MainActor in
            state.userTranscript = text
            state.aiTranscript = ""
            state.status = .thinking
        }

        let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)
        let prompt: String
        let maxTokens: Int
        if #available(iOS 18.0, *) {
            // Qwen3 instruct chat template
            prompt = "<|im_start|>system\n\(persona.instructions)<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
            maxTokens = 128
        } else {
            // Llama-3 instruct chat template (iOS 17 fallback)
            prompt = "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n\(persona.instructions)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(text)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
            maxTokens = 30
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
        let utterance = AVSpeechUtterance(string: text)

        // Select an appropriate voice based on Persona
        let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)
        let language = persona.instructions.contains("Japanese") ? "ja-JP" : "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.1

        // Use the write() API to intercept audio buffers instead of playing directly.
        // This allows us to route it through AVAudioEngine to measure amplitude for lip-sync.
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self = self, let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

            // Prevent AVAudioBuffer crash on EOF
            guard pcmBuffer.frameLength > 0 else { return }

            // AVSpeechSynthesizer can change formats depending on the voice (22050Hz vs 24000Hz).
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

            self.playerNode.scheduleBuffer(pcmBuffer)
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
        Task { @MainActor in
            if state.status == .thinking {
                state.status = .speaking
            }
            state.aiTranscript += token
        }

        // Buffer tokens. When we hit a punctuation mark, synthesize speech.
        ttsBuffer += token
        if token.contains(".") || token.contains("!") || token.contains("?")
            || token.contains("。") || token.contains(",") || token.contains("\n") {
            let chunkToSpeak = ttsBuffer
            ttsBuffer = ""
            speakChunk(chunkToSpeak)
        }
    }

    func localLLM(didFinishGeneration fullText: String) {
        // Flush any remaining text in the buffer
        if !ttsBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            speakChunk(ttsBuffer)
            ttsBuffer = ""
        }
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

// MARK: - SileroVADDelegate

extension LocalLLMManager: SileroVADDelegate {
    func sileroVADDidDetectVoiceStart() {
        Task { @MainActor in
            if state.status == .ready {
                state.status = .listening
            }
        }
        recordingLock.lock()
        isRecordingVoice = true
        // Keep the pre-roll buffer intact so we don't lose the first word
        recordingLock.unlock()
    }

    func sileroVADDidDetectVoiceEnd(wavData: Data?) {
        Task { @MainActor in
            if state.status == .listening {
                state.status = .ready
            }
        }

        recordingLock.lock()
        isRecordingVoice = false
        var rawSamples = recordingBuffer
        recordingBuffer.removeAll(keepingCapacity: true)  // Clear buffer for next utterance
        recordingLock.unlock()

        // VAD requires ~1.8s of silence to trigger the voice end.
        // We drop the last 1.5s of trailing silence to tightly bound the speech.
        // This prevents short utterances from being diluted by silence and rejected by Whisper.
        let sr = hardwareInputFormat?.sampleRate ?? 48000.0
        let dropFrames = Int(sr * 1.5)
        let minKeep = Int(sr * 0.5)  // Always keep at least 0.5s of audio
        if rawSamples.count > dropFrames + minKeep {
            rawSamples.removeLast(dropFrames)
        }

        guard !rawSamples.isEmpty else { return }

        // Pass to WhisperKit for local transcription
        Task {
            guard let inputFmt = hardwareInputFormat,
                let targetFmt = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1,
                    interleaved: false),
                let converter = AVAudioConverter(from: inputFmt, to: targetFmt)
            else {
                print("[LocalAI]: Failed to create AVAudioConverter.")
                return
            }

            // Create input buffer matching hardware format
            let frameCapacity = AVAudioFrameCount(rawSamples.count)
            guard
                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFmt, frameCapacity: frameCapacity)
            else { return }
            inputBuffer.frameLength = frameCapacity

            if let channelData = inputBuffer.floatChannelData {
                // If input format is stereo, populate both channels to prevent garbage during mixdown
                for channel in 0..<Int(inputFmt.channelCount) {
                    rawSamples.withUnsafeBufferPointer { ptr in
                        channelData[channel].assign(from: ptr.baseAddress!, count: rawSamples.count)
                    }
                }
            }

            // Convert to 16kHz Mono
            let outCapacity = AVAudioFrameCount(
                ceil(Double(rawSamples.count) * 16000.0 / inputFmt.sampleRate))
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFmt, frameCapacity: outCapacity)
            else { return }

            var error: NSError?
            var providedData = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if providedData {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedData = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if let error = error {
                print("[LocalAI]: AVAudioConverter Error at end: \(error)")
                return
            }

            guard let outChannelData = outputBuffer.floatChannelData else { return }
            let outLength = Int(outputBuffer.frameLength)
            let whisperSamples = Array(
                UnsafeBufferPointer(start: outChannelData[0], count: outLength))

            await whisperManager.transcribe(samples: whisperSamples)
        }
    }
}

// MARK: - LocalWhisperManagerDelegate

extension LocalLLMManager: LocalWhisperManagerDelegate {
    func whisperManager(didTranscribeText text: String) {
        // Feed the localized transcription directly to the Local LLM
        handleUserInput(text)
    }

    func whisperManager(didFailWithError error: Error) {
        Task { @MainActor in
            state.setError("Whisper Error: \(error.localizedDescription)")
        }
    }
}
