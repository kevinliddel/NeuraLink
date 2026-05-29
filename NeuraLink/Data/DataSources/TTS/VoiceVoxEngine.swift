//
//  VoiceVoxEngine.swift
//  NeuraLink
//
//  Swift wrapper around the VOICEVOX 0.16.4+ Synthesizer C API.
//  Lifted from feat/voice-vox at Phase 1a and adapted to the unified
//  `TTSEngineProtocol` (push-streaming via `onBufferReady`, persona-keyed
//  `speak(_:persona:)`). The original pull-style `synthesize(text:speakerID:)`
//  is kept as a public helper for callers that want raw WAV bytes (e.g. unit
//  tests, debug surfaces).
//
//  Created by Dedicatus on 29/04/2026.
//

import AVFoundation
import Foundation

final class VoiceVoxEngine: NSObject, @unchecked Sendable, TTSEngineProtocol {

    // MARK: - Singleton

    static let shared = VoiceVoxEngine()

    // MARK: - TTSEngineProtocol

    private(set) var isReady = false

    var onBufferReady: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Internals

    private let queue = DispatchQueue(label: "com.neuralink.voicevox.engine", qos: .userInitiated)
    private var isInitializing = false

    private var synthesizer: OpaquePointer?
    private var onnxRuntime: OpaquePointer?
    private var openJtalk: OpaquePointer?

    private var loadedModelIDs = Set<String>()
    private var modelHandles = [String: OpaquePointer]()

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

        // Pre-resolve the Open JTalk dict path. Triggers a parallel
        // download of all dict files on first run for users whose
        // bundle has been stripped; returns instantly otherwise.
        let dicPath: String
        do {
            guard let path = try await VoiceVoxModelAccess.dictionaryPath() else {
                throw TTSError.modelNotFound
            }
            dicPath = path
        } catch {
            nlLog("[VoiceVox] Dictionary resolve failed: \(error)", level: .warning)
            throw TTSError.modelNotFound
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {

                let ortResult = voicevox_onnxruntime_init_once(&self.onnxRuntime)
                guard Int32(ortResult) == 0 else {
                    cont.resume(throwing: TTSError.initializationFailed(
                        reason: "ONNX Runtime init failed: \(ortResult)"
                    ))
                    return
                }

                let jtalkResult = voicevox_open_jtalk_rc_new(
                    (dicPath as NSString).utf8String,
                    &self.openJtalk
                )
                guard Int32(jtalkResult) == 0 else {
                    cont.resume(throwing: TTSError.initializationFailed(
                        reason: "OpenJtalk init failed: \(jtalkResult)"
                    ))
                    return
                }

                var options = voicevox_make_default_initialize_options()
                options.cpu_num_threads = 4  // sweet spot for iPhone, avoids contention

                let synthResult = voicevox_synthesizer_new(
                    self.onnxRuntime, self.openJtalk, options, &self.synthesizer
                )
                guard Int32(synthResult) == 0 else {
                    cont.resume(throwing: TTSError.initializationFailed(
                        reason: "Synthesizer creation failed: \(synthResult)"
                    ))
                    return
                }

                self.isReady = true
                nlLog("[VoiceVox] Engine 0.16.4 initialized.", level: .info)
                cont.resume()
            }
        }
    }

    func shutdown() {
        queue.sync {
            guard isReady else { return }
            if let syn = synthesizer {
                voicevox_synthesizer_delete(syn)
                synthesizer = nil
            }
            if let jtalk = openJtalk {
                voicevox_open_jtalk_rc_delete(jtalk)
                openJtalk = nil
            }
            for handle in modelHandles.values {
                voicevox_voice_model_file_delete(handle)
            }
            modelHandles.removeAll()
            loadedModelIDs.removeAll()
            isReady = false
            nlLog("[VoiceVox] Engine shutdown.", level: .info)
        }
    }

    func stop() {
        // VOICEVOX synthesis is a single blocking C call; there is no in-flight
        // cancellation hook. Playback-side stop is handled by `LocalLLMManager`'s
        // AVAudioPlayerNode. This is a deliberate no-op.
    }

    // MARK: - TTSEngineProtocol.speak

    func speak(_ text: String, persona: PersonaIdentifier) async throws {
        guard isReady else { throw TTSError.notInitialized }

        let speakerID = VoiceVoxSpeaker.speakerID(for: persona)
        let wav = try await synthesize(text: text, speakerID: speakerID)

        guard let buffer = AudioDataConverter.pcmBuffer(from: wav) else {
            throw TTSError.synthesisFailed(reason: "WAV->PCMBuffer conversion failed")
        }

        onBufferReady?(buffer)
    }

    // MARK: - Pull-style API (kept for tests and JP debug surfaces)

    /// Synthesizes `text` for the given VOICEVOX speaker ID and returns WAV bytes.
    /// Public so callers that want raw audio (unit tests, debug UIs) can use it
    /// without going through the streaming callback.
    func synthesize(text: String, speakerID: Int) async throws -> Data {
        guard isReady else { throw TTSError.notInitialized }

        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return Data() }

        // Pre-resolve the speaker `.vvm` URL. Triggers a download on
        // first use of this speaker for users whose bundle has been
        // stripped; returns instantly for bundled or already-cached
        // speakers. Pre-resolving here keeps the cache lookup off the
        // synthesis queue and avoids re-entering Swift concurrency
        // from inside the C bridge call.
        let mapping = VoiceVoxSpeaker.map(speakerID)
        let characterID = mapping.filenameID
        let internalStyleID = mapping.internalStyleID
        let resolvedModelURL: URL
        do {
            guard let url = try await VoiceVoxModelAccess.modelURL(forSpeakerID: characterID) else {
                throw TTSError.modelNotFound
            }
            resolvedModelURL = url
        } catch {
            nlLog("[VoiceVox] Speaker resolve failed (id=\(characterID)): \(error)", level: .warning)
            throw TTSError.modelNotFound
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                if !self.loadedModelIDs.contains("\(characterID)") {
                    let modelPath = resolvedModelURL.path

                    var file: OpaquePointer?
                    let openResult = voicevox_voice_model_file_open(
                        (modelPath as NSString).utf8String, &file
                    )
                    guard Int32(openResult) == 0, let modelFile = file else {
                        cont.resume(throwing: TTSError.modelNotFound)
                        return
                    }

                    let loadResult = voicevox_synthesizer_load_voice_model(self.synthesizer, modelFile)
                    if Int32(loadResult) == 0 {
                        self.modelHandles[modelPath] = modelFile
                        self.loadedModelIDs.insert("\(characterID)")
                    } else {
                        voicevox_voice_model_file_delete(modelFile)
                        cont.resume(throwing: TTSError.synthesisFailed(
                            reason: "Model load failed: \(loadResult)"
                        ))
                        return
                    }
                }

                var queryJsonPtr: UnsafeMutablePointer<Int8>?
                let queryResult = voicevox_synthesizer_create_audio_query(
                    self.synthesizer,
                    (cleanText as NSString).utf8String,
                    VoicevoxStyleId(internalStyleID),
                    &queryJsonPtr
                )
                guard Int32(queryResult) == 0, let originalJsonPtr = queryJsonPtr else {
                    cont.resume(throwing: TTSError.synthesisFailed(
                        reason: "Query creation failed: \(queryResult)"
                    ))
                    return
                }

                var queryJson = String(cString: originalJsonPtr)
                voicevox_json_free(originalJsonPtr)

                queryJson = queryJson.replacingOccurrences(
                    of: "\"speedScale\":1.0", with: "\"speedScale\":1.1"
                )
                queryJson = queryJson.replacingOccurrences(
                    of: "\"intonationScale\":1.0", with: "\"intonationScale\":1.5"
                )

                var outputSize: Int = 0
                var outputData: UnsafeMutablePointer<UInt8>?
                let start = DispatchTime.now()

                let synthResult = voicevox_synthesizer_synthesis(
                    self.synthesizer,
                    (queryJson as NSString).utf8String,
                    VoicevoxStyleId(internalStyleID),
                    voicevox_make_default_synthesis_options(),
                    &outputSize,
                    &outputData
                )

                if Int32(synthResult) == 0, let dataPtr = outputData {
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
                    nlLog(
                        "[VoiceVox] Synthesised \(outputSize) bytes in \(String(format: "%.1f", elapsed))s",
                        level: .info
                    )
                    let data = Data(bytes: dataPtr, count: Int(outputSize))
                    voicevox_wav_free(dataPtr)
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: TTSError.synthesisFailed(
                        reason: "Synthesis failed with code \(synthResult)"
                    ))
                }
            }
        }
    }
}
