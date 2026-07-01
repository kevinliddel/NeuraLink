//
//  AudioDataConverter.swift
//  NeuraLink
//
//  Utility to convert raw audio Data (WAV/PCM) into AVAudioPCMBuffer.
//  Single source of truth for the bytes <-> buffer conversion path used by
//  every TTS engine.
//
//  Created by Dedicatus on 29/04/2026.
//

import AVFoundation
import Foundation

enum AudioDataConverter {

    /// Converts a WAV file in `Data` form into an `AVAudioPCMBuffer`. Handles
    /// standard 16-bit PCM WAV by round-tripping through `AVAudioFile`, which
    /// parses the WAV header for us — safer than manual byte parsing.
    /// Used by VOICEVOX which returns synthesised audio as WAV bytes.
    static func pcmBuffer(from data: Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty else { return nil }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")

        do {
            try data.write(to: tempURL)
            let file = try AVAudioFile(forReading: tempURL)

            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(file.length)
                )
            else { return nil }

            try file.read(into: buffer)
            try? FileManager.default.removeItem(at: tempURL)
            return buffer
        } catch {
            nlLog("[AudioConverter] Error converting data to buffer: \(error)", level: .error)
            return nil
        }
    }

    /// Converts raw mono float samples into an `AVAudioPCMBuffer`.
    /// Emits float-array output from its Vocos vocoder.
    /// Returns nil — never crashes — if the format or samples are invalid.
    static func toPCMBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        // AVAudioFormat(standardFormatWithSampleRate:channels:) raises an
        // NSException (not a Swift error) if sampleRate <= 0 — validate first.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }

        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData {
            channelData[0].update(from: samples, count: samples.count)
        }
        return buffer
    }
}
