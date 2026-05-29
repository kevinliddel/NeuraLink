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

        let threads = Self.intraOpThreadCount()

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

                nlLog("[Kokoro] Initializing bridge: model=\(modelPath), voices=\(voicesPath), threads=\(threads)", level: .info)

                guard let initializedBridge = KokoroBridge(
                    modelPath: modelPath,
                    voicesPath: voicesPath,
                    vocabPath: vocabPath,
                    dictPath: dictPath,
                    intraOpThreads: Int32(threads)
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

    /// Returns the ONNX intra-op thread count to use for this device tier.
    /// iPhone 11 (4 GB) stays single-threaded — combined RSS with a 1B-class
    /// local LLM pushes the jetsam ceiling, and kokoro.onnx alone is 328 MB.
    /// 6 GB+ devices get 2 threads, matching the P-core count on A14–A17 for
    /// a clean ~2× per-batch decode without growing the arena footprint.
    private static func intraOpThreadCount() -> Int {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return gb > 4.0 ? 2 : 1
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

        let voiceName = KokoroVoicePreset.preset(for: persona).identifier

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try bridge.synthesizeStreamingText(
                        cleanText,
                        voiceName: voiceName,
                        speed: 1.0
                    ) { batchData in
                        let floatCount = batchData.count / MemoryLayout<Float>.size
                        guard floatCount > 0 else { return }
                        var samples = [Float](repeating: 0, count: floatCount)
                        samples.withUnsafeMutableBytes { rawBuffer in
                            _ = batchData.copyBytes(to: rawBuffer)
                        }
                        guard let pcm = AudioDataConverter.toPCMBuffer(
                            samples: samples,
                            sampleRate: 24000
                        ) else { return }
                        self.onBufferReady?(pcm)
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: TTSError.synthesisFailed(reason: error.localizedDescription))
                }
            }
        }
    }
}
