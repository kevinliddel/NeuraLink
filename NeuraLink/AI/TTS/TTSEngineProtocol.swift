//
//  TTSEngineProtocol.swift
//  NeuraLink
//
//  Unified interface for all Text-to-Speech backends.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

/// Defines the standard operations for a Local TTS Engine.
protocol TTSEngineProtocol: AnyObject, Sendable {
    
    /// Whether the engine is initialized and ready to synthesize.
    var isReady: Bool { get }
    
    /// Initializes the engine with local resources.
    func initialize() async throws
    
    /// Synthesizes text into PCM audio data.
    /// - Parameters:
    ///   - text: The Japanese text to synthesize.
    ///   - speakerID: The character/style ID.
    /// - Returns: Data containing the WAV/PCM audio.
    func synthesize(text: String, speakerID: Int) async throws -> Data
    
    /// Frees resources when no longer needed.
    func shutdown()
}

enum TTSError: Error {
    case notInitialized
    case synthesisFailed(reason: String)
    case dictionaryNotFound
    case modelNotLoaded
}
