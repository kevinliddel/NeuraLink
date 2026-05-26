//
//  TTSEngineProtocol.swift
//  NeuraLink
//
//  Unified post-merge contract for local TTS engines.
//
//  Resolves the protocol conflict between feat/voice-cloning's TTSProtocol
//  (push-streaming via onBufferReady callback) and feat/voice-vox's
//  TTSEngineProtocol (pull via synthesize -> Data). The push model wins —
//  it matches LocalLLMManager+TTS's existing sentence-chunked playback path
//  and keeps first-audio latency low. A one-shot Data form is provided as a
//  default-implemented extension for callers that want bytes.
//
//  Created by Dedicatus on 26/05/2026.
//

import AVFoundation
import Foundation

// MARK: - Persona identifier

typealias PersonaIdentifier = String

// MARK: - Errors

enum TTSError: LocalizedError, Equatable {
    case notInitialized
    case modelNotFound
    case initializationFailed(reason: String)
    case synthesisFailed(reason: String)
    case unsupportedPersona(PersonaIdentifier)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "TTS engine is not initialized. Call initialize() first."
        case .modelNotFound:
            return "TTS model files not found. Please download the voice pack first."
        case .initializationFailed(let reason):
            return "Failed to initialise the TTS engine: \(reason)."
        case .synthesisFailed(let reason):
            return "Speech synthesis failed: \(reason)."
        case .unsupportedPersona(let persona):
            return "This engine does not support persona '\(persona)'."
        }
    }
}

// MARK: - Engine protocol

protocol TTSEngineProtocol: AnyObject {
    var isReady: Bool { get }

    var onBufferReady: ((AVAudioPCMBuffer) -> Void)? { get set }

    func initialize() async throws

    func speak(_ text: String, persona: PersonaIdentifier) async throws

    func stop()

    func shutdown()
}

extension TTSEngineProtocol {

    func synthesize(_ text: String, persona: PersonaIdentifier) async throws -> Data {
        var collected = Data()
        let previousCallback = onBufferReady
        defer { onBufferReady = previousCallback }

        onBufferReady = { buffer in
            guard let floatChannel = buffer.floatChannelData?[0] else { return }
            let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
            collected.append(Data(bytes: floatChannel, count: byteCount))
        }

        try await speak(text, persona: persona)
        return collected
    }
}
