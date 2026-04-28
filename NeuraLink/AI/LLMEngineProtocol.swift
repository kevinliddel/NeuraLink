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

enum LLMError: LocalizedError {
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
}
