//
//  AudioDataConverter.swift
//  NeuraLink
//
//  Utility to convert raw audio Data (WAV/PCM) into AVAudioPCMBuffer.
//
//  Created by Dedicatus on 29/04/2026.
//

import AVFoundation
import Foundation

enum AudioDataConverter {
    
    /// Converts a WAV file in Data format to an AVAudioPCMBuffer.
    /// Supports standard 16-bit PCM WAV.
    static func pcmBuffer(from data: Data) -> AVAudioPCMBuffer? {
        // We use AVAudioFile to handle the WAV header parsing for us.
        // This is safer than manual byte-parsing.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        
        do {
            try data.write(to: tempURL)
            let file = try AVAudioFile(forReading: tempURL)
            
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { return nil }
            
            try file.read(into: buffer)
            
            // Clean up
            try? FileManager.default.removeItem(at: tempURL)
            
            return buffer
        } catch {
            print("[AudioConverter] Error converting data to buffer: \(error)")
            return nil
        }
    }
}
