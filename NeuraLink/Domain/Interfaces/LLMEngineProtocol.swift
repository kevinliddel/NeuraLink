//
//  LLMEngineProtocol.swift
//  NeuraLink
//
//  Defines the shared engine contract, its callback delegate, and common errors.
//
//  Created by Dedicatus on 27/04/2026.
//

import Foundation

// MARK: - Errors

enum LLMError: LocalizedError, Equatable {
    case modelNotFound
    case initializationFailed
    case inferenceFailed
    case loadTimeout(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Local model files not found. Please download the model first."
        case .initializationFailed:
            return "Failed to initialise the local LLM engine."
        case .inferenceFailed:
            return "Inference failed unexpectedly."
        case .loadTimeout(let label):
            return "Timed out loading \(label). The model file may be corrupted — try deleting and re-downloading it."
        }
    }
}

// MARK: - Chat message

/// A single conversation turn fed to a local LLM. Mirrors the OpenAI/HF
/// chat-completions shape so the same role names work across every engine.
struct LLMChatMessage {
    let role: String       // "system" / "user" / "assistant"
    let content: String
}

// MARK: - Delegate

protocol LocalLLMEngineDelegate: AnyObject {
    func localLLM(didGenerateToken token: String)
    func localLLM(didFinishGeneration fullText: String)
    func localLLM(didFailWithError error: Error)
}

// MARK: - Engine protocol

protocol LLMEngineProtocol: AnyObject {
    var delegate: LocalLLMEngineDelegate? { get set }
    var isLoaded: Bool { get }
    func loadModel() async throws
    func generate(prompt: String, maxTokens: Int) async
    func stop()
    func unloadModel()

    /// Formats `messages` into a single prompt string using the loaded model's
    /// own chat template (read from GGUF metadata). Returns `nil` if the model
    /// is not loaded or has no embedded template — callers should then fall
    /// back to a hand-rolled template.
    func applyChatTemplate(messages: [LLMChatMessage]) -> String?
}
