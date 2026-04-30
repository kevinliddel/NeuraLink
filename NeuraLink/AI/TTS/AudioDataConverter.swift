//
//  AudioDataConverter.swift
//  NeuraLink
//
//  Created by Antigravity on 29/04/2026.
//

import AVFoundation
import Foundation

struct AudioDataConverter {

    /// Converts raw float samples (mono) into an AVAudioPCMBuffer.
    /// Returns nil — never crashes — if the format or samples are invalid.
    static func toPCMBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }

        // AVAudioFormat(standardFormatWithSampleRate:channels:) raises an NSException
        // (not a Swift error) if sampleRate <= 0 — validate before calling.
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
