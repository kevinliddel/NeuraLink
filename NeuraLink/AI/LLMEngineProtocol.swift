//
//  LLMEngineProtocol.swift
//  NeuraLink
//
//  Created by Dedicatus on 27/04/2026.
//

import Foundation

protocol LLMEngineProtocol: AnyObject {
    var delegate: LocalLLMEngineDelegate? { get set }
    var isLoaded: Bool { get }
    func loadModel() async throws
    func generate(prompt: String, maxTokens: Int) async
    func stop()
}
