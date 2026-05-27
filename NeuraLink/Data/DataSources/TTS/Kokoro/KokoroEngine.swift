//
//  KokoroEngine.swift
//  NeuraLink
//
//  Swift wrapper implementing TTSEngineProtocol for Kokoro C++ TTS Engine.
//

import AVFoundation
import Foundation

final class KokoroEngine: NSObject, @unchecked Sendable, TTSEngineProtocol {

    // MARK: - Singleton

    static let shared = KokoroEngine()

    // MARK: - TTSEngineProtocol

    private(set) var isReady = false

    var onBufferReady: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Internals

    private let queue = DispatchQueue(label: "com.neuralink.kokoro.engine", qos: .userInitiated)
    private var isInitializing = false
    private var bridge: KokoroBridge?

    // MARK: - Init / deinit

    override private init() {
        super.init()
    }

    deinit {
        shutdown()
    }

    // MARK: - Lifecycle

    func initialize() async throws {
        if isReady { return }
        guard !isInitializing else { return }
        isInitializing = true
        defer { isInitializing = false }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard KokoroModelAccess.isAvailable else {
                    cont.resume(throwing: TTSError.modelNotFound)
                    return
                }

                let modelPath = KokoroModelAccess.kokoroModel.path
                let voicesPath = KokoroModelAccess.voicesBin.path
                let vocabPath = KokoroModelAccess.vocabTxt.path
                let dictPath = KokoroModelAccess.cmuDict.path

                nlLog("[Kokoro] Initializing bridge with paths: model=\(modelPath), voices=\(voicesPath)", level: .info)

                guard let initializedBridge = KokoroBridge(
                    modelPath: modelPath,
                    voicesPath: voicesPath,
                    vocabPath: vocabPath,
                    dictPath: dictPath
                ) else {
                    cont.resume(throwing: TTSError.initializationFailed(reason: "KokoroBridge failed to instantiate"))
                    return
                }

                self.bridge = initializedBridge
                self.isReady = true
                nlLog("[Kokoro] C++ Engine initialized successfully.", level: .info)
                cont.resume()
            }
        }
    }

    func shutdown() {
        queue.sync {
            guard isReady else { return }
            bridge = nil
            isReady = false
            nlLog("[Kokoro] C++ Engine shutdown.", level: .info)
        }
    }

    func stop() {
        // Kokoro C++ synthesis runs synchronously on our background queue;
        // stop/cancellation is managed by LocalLLMManager's audio player node.
    }

    // MARK: - TTSEngineProtocol.speak

    func speak(_ text: String, persona: PersonaIdentifier) async throws {
        guard isReady, let bridge = bridge else { throw TTSError.notInitialized }

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let voiceName = KokoroVoicePreset.preset(for: persona).identifier
                
                do {
                    let data = try bridge.synthesizeText(cleanText, voiceName: voiceName, speed: 1.0)
                    
                    let floatCount = data.count / MemoryLayout<Float>.size
                    var samples = [Float](repeating: 0, count: floatCount)
                    samples.withUnsafeMutableBytes { buffer in
                        _ = data.copyBytes(to: buffer)
                    }

                    guard let buffer = AudioDataConverter.toPCMBuffer(samples: samples, sampleRate: 24000) else {
                        cont.resume(throwing: TTSError.synthesisFailed(reason: "PCM float samples to buffer conversion failed"))
                        return
                    }

                    self.onBufferReady?(buffer)
                    cont.resume()
                } catch {
                    cont.resume(throwing: TTSError.synthesisFailed(reason: error.localizedDescription))
                }
            }
        }
    }
}
