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
        playerNode.volume = 2.5

        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)

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
