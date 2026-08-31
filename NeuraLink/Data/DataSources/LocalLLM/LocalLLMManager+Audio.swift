//
//  LocalLLMManager+Audio.swift
//  NeuraLink
//
//  Audio engine setup and processing split out to keep LocalLLMManager.swift lean.
//
//  Created by Dedicatus on 09/05/2026.
//

import AVFoundation
import Foundation

extension LocalLLMManager {
    
    func setupAudioEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)

            if let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
        } catch {
            nlLog("[LocalAI]: Failed to configure audio session: \(error)", level: .error)
        }

        audioEngine.attach(playerNode)
        audioEngine.attach(ttsMixerNode)
        playerNode.volume = 2.5

        // Hardware acoustic echo cancellation + noise suppression + AGC,
        // enabled on the input node BEFORE any taps install so the
        // negotiated input format is the voice-processing one (typically
        // 24 kHz mono). This is the structural fix for speaker-to-mic
        // leakage that previously required the 800 ms mic gate cool-down
        // in `processCapturedAudio`. The gate stays in place as a
        // belt-and-suspenders fallback for the brief window between
        // .speaking and .ready before AEC has converged on the new echo.
        do {
            try audioEngine.inputNode.setVoiceProcessingEnabled(true)
            nlLog("[LocalAI]: Voice processing enabled on input node (AEC/AGC/NS).", level: .info)
        } catch {
            nlLog("[LocalAI]: setVoiceProcessingEnabled failed (\(error)) — falling back to mic-gate cool-down only.", level: .error)
        }

        // player → ttsMixer carries whatever the active TTS engine emits
        // (re-wired by `scheduleBuffer` when the engine/sample-rate changes);
        // ttsMixer → mainMixer is pinned at 48 kHz so those changes never
        // propagate into the downstream graph (M5 — the mixer does the SRC).
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        audioEngine.connect(playerNode, to: ttsMixerNode, format: format)
        let ttsMixerFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        audioEngine.connect(ttsMixerNode, to: audioEngine.mainMixerNode, format: ttsMixerFormat)

        let mixFmt = audioEngine.mainMixerNode.outputFormat(forBus: 0)
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixFmt) {
            [weak self] buffer, _ in
            self?.reportAmplitude(buffer)
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        self.hardwareInputFormat = inputFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            self?.processCapturedAudio(buffer: buffer)
        }

        do {
            try audioEngine.start()
            nlLog("[LocalAI]: AVAudioEngine started for local TTS & Input Capture.", level: .info)
        } catch {
            nlLog("[LocalAI]: Failed to start audio engine: \(error)", level: .error)
        }
    }

    /// Extends the mic self-loop gate so ambient audio (e.g. music during a
    /// song-recognition session) never reaches the VAD and triggers a
    /// spurious user turn. Passing a short value hands the gate back to the
    /// normal cool-down; while the AI is busy `processCapturedAudio` keeps
    /// bumping the gate forward regardless, so a short release is safe.
    func gateMicCapture(forSeconds seconds: TimeInterval) {
        micGatedUntilUptime = ProcessInfo.processInfo.systemUptime + seconds
    }

    func reportAmplitude(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let length = Int(buffer.frameLength)
        guard length > 0 else { return }

        var sum: Float = 0
        for i in 0..<length {
            sum += channelData[0][i] * channelData[0][i]
        }
        let rms = sqrt(sum / Float(length))

        Task { @MainActor in
            self.state.audioLevel = min(rms * 5.0, 1.0)
        }
    }

    func processCapturedAudio(buffer: AVAudioPCMBuffer) {
        // Self-loop guard: drop mic frames while the AI is producing audio
        // and for a short cool-down after it stops. iOS doesn't apply
        // hardware echo cancellation under `.default` audio session mode,
        // so without this gate the speaker output bleeds into the mic, VAD
        // treats it as user speech, and the AI gets stuck talking to
        // itself (observed on iPhone 11 with Llama-1B and Qwen-7B).
        //
        // The TTS `dataConsumed` callback fires when audio is handed to
        // the system audio buffer — not when speakers stop emitting — so
        // there's ~100–300 ms of playback tail after status flips to
        // .ready. The 0.8 s extension covers that plus room decay.
        let now = ProcessInfo.processInfo.systemUptime
        let status = state.status
        if status == .thinking || status == .speaking {
            // Bump the gate forward so cool-down counts from the LAST
            // AI-busy sample, not the first.
            micGatedUntilUptime = now + 0.8
            return
        }
        if now < micGatedUntilUptime {
            return
        }

        sileroVAD.processAudioBuffer(buffer)

        recordingLock.lock()
        defer { recordingLock.unlock() }

        if let channelData = buffer.floatChannelData {
            let length = Int(buffer.frameLength)
            let pointer = channelData[0]
            let floatArray = Array(UnsafeBufferPointer(start: pointer, count: length))
            recordingBuffer.append(contentsOf: floatArray)

            if !isRecordingVoice {
                let maxPreRoll = Int((hardwareInputFormat?.sampleRate ?? 48000.0) * 0.5)
                if recordingBuffer.count > maxPreRoll {
                    recordingBuffer.removeFirst(recordingBuffer.count - maxPreRoll)
                }
            } else {
                let sampleRate = hardwareInputFormat?.sampleRate ?? 48000.0
                let newSamples = recordingBuffer.count - lastPartialTranscribedCount
                if newSamples >= Int(sampleRate * 0.8), !isTranscribingPartial {
                    let currentBuffer = recordingBuffer
                    triggerPartialTranscription(samples: currentBuffer)
                }
            }
        }
    }
}
