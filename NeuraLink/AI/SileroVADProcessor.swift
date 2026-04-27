//
//  SileroVADProcessor.swift
//  NeuraLink
//
//  Created by Dedicatus on 20/04/2026.
//

import AVFoundation
import RealTimeCutVADLibrary

/// Callback interface for Silero voice activity events.
protocol SileroVADDelegate: AnyObject {
    func sileroVADDidDetectVoiceStart()
    func sileroVADDidDetectVoiceEnd(wavData: Data?)
}

/// Local voice activity detector backed by the Silero VAD model.
/// Runs alongside OpenAI's server_vad to provide instant client-side
/// listening state without waiting for a server round-trip.
final class SileroVADProcessor: NSObject {
    weak var delegate: SileroVADDelegate?
    private(set) var isVoiceActive = false

    private var audioEngine: AVAudioEngine?
    private var vadWrapper: VADWrapper?

    // MARK: - Lifecycle

    /// Starts the Silero VAD engine. If `externalSampleRate` is provided, it expects audio
    /// via `processAudioBuffer(_:)` and will NOT start its internal microphone tap.
    func start(externalSampleRate: Double? = nil) {
        guard vadWrapper == nil else { return }
        guard let wrapper = VADWrapper() else {
            print("[SileroVAD]: VADWrapper init failed")
            return
        }
        wrapper.delegate = self
        wrapper.setSileroModel(.v5)
        vadWrapper = wrapper

        if let rate = externalSampleRate {
            wrapper.setSamplerate(mappedSampleRate(rate))
            print("[SileroVAD]: Started at \(Int(rate)) Hz")
        } else {
            startAudioCapture()
        }
    }

    /// Processes an external audio buffer when not using the internal microphone tap.
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let wrapper = vadWrapper else { return }
        guard let channelData = buffer.floatChannelData else { return }
        wrapper.processAudioData(withBuffer: channelData[0], count: UInt(buffer.frameLength))
    }

    /// Stops the engine and releases all resources.
    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        vadWrapper = nil
        isVoiceActive = false
        print("[SileroVAD]: Stopped")
    }

    // MARK: - Audio Capture

    private func startAudioCapture() {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        vadWrapper?.setSamplerate(mappedSampleRate(inputFormat.sampleRate))

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            self?.vadWrapper?.processAudioData(
                withBuffer: channelData[0], count: UInt(buffer.frameLength))
        }

        do {
            try engine.start()
            audioEngine = engine
            print("[SileroVAD]: Started at \(Int(inputFormat.sampleRate)) Hz")
        } catch {
            // Non-fatal: server_vad remains the fallback when AVAudioEngine
            // cannot coexist with WebRTC's VoiceProcessingIO audio unit.
            print("[SileroVAD]: Engine start failed, server_vad handles detection: \(error)")
            inputNode.removeTap(onBus: 0)
            vadWrapper = nil
        }
    }

    private func mappedSampleRate(_ rate: Double) -> SL {
        switch Int(rate) {
        case 8_000: return .SAMPLERATE_8
        case 16_000: return .SAMPLERATE_16
        case 24_000: return .SAMPLERATE_24
        default: return .SAMPLERATE_48
        }
    }
}

// MARK: - VADDelegate

extension SileroVADProcessor: VADDelegate {
    func voiceStarted() {
        isVoiceActive = true
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.sileroVADDidDetectVoiceStart()
        }
    }

    func voiceEnded(withWavData wavData: Data!) {
        isVoiceActive = false
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.sileroVADDidDetectVoiceEnd(wavData: wavData)
        }
    }

    // PCM stream during active speech — reserved for future local transcription.
    func voiceDidContinue(withPCMFloat _: Data!) {}
}
