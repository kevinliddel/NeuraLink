//
//  TTSProtocol.swift
//  NeuraLink
//
//  Created by Antigravity on 29/04/2026.
//

import AVFoundation

/// Protocol for all Text-to-Speech engines in NeuraLink.
protocol TTSProtocol: AnyObject {
    /// Callback for when a new audio buffer is ready for playback/processing.
    var onBufferReady: ((AVAudioPCMBuffer) -> Void)? { get set }
    
    /// Synthesizes the given text.
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - characterName: The name of the character (for voice selection).
    func speak(_ text: String, for characterName: String)
    
    /// Stops all current speech synthesis.
    func stop()
    
    /// Whether the engine is ready to synthesize.
    var isReady: Bool { get }
}
