//
//  LocalLLMManager+Delegates.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import AVFoundation
import Foundation

// MARK: - SileroVADDelegate

extension LocalLLMManager: SileroVADDelegate {
    func sileroVADDidDetectVoiceStart() {
        // Guard on MainActor so we only start recording when truly in .ready state.
        // This prevents the VAD from treating speaker output as user speech while the
        // AI is speaking (.speaking / .thinking), which would cause a self-reply loop.
        Task { @MainActor in
            guard state.status == .ready else { return }
            state.status = .listening
            recordingLock.lock()
            isRecordingVoice = true
            // Keep the pre-roll buffer intact so we don't lose the first word
            recordingLock.unlock()
        }
    }

    func sileroVADDidDetectVoiceEnd(wavData: Data?) {
        recordingLock.lock()
        // wasTrulyRecording is false when voice started during .speaking/.thinking,
        // meaning isRecordingVoice was never set — so we have no real user audio to transcribe.
        let wasTrulyRecording = isRecordingVoice
        isRecordingVoice = false
        var rawSamples = recordingBuffer
        recordingBuffer.removeAll(keepingCapacity: true)  // Clear buffer for next utterance
        recordingLock.unlock()

        Task { @MainActor in
            if state.status == .listening {
                state.status = .ready
            }
        }

        guard wasTrulyRecording else { return }

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
