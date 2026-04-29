//
//  VoiceVoxEngine.swift
//  NeuraLink
//
//  Swift implementation of the VOICEVOX TTS engine (v0.16.4+).
//  Handles the interaction with the new Synthesizer-based C API.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

final class VoiceVoxEngine: NSObject, @unchecked Sendable, TTSEngineProtocol {

    // MARK: - Singleton

    static let shared = VoiceVoxEngine()

    // MARK: - Properties

    private(set) var isReady = false
    private let queue = DispatchQueue(label: "com.neuralink.voicevox.engine", qos: .userInitiated)

    // Opaque pointers to C objects
    private var synthesizer: OpaquePointer?
    private var onnxRuntime: OpaquePointer?
    private var openJtalk: OpaquePointer?
    
    // Track loaded model IDs and their handles to prevent data invalidation
    private var loadedModelIDs = Set<String>()
    private var modelHandles = [String: OpaquePointer]()

    // MARK: - Init

    override private init() {
        super.init()
    }

    deinit {
        shutdown()
    }

    // MARK: - TTSEngineProtocol

    func initialize() async throws {
        if isReady { return }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let dicPath = VoiceVoxModelAccess.dictionaryPath() else {
                    cont.resume(throwing: TTSError.dictionaryNotFound)
                    return
                }

                // 1. Initialize ONNX Runtime (Singletone on iOS)
                let ortResult = voicevox_onnxruntime_init_once(&self.onnxRuntime)
                guard Int32(ortResult) == 0 else {
                    cont.resume(throwing: TTSError.synthesisFailed(reason: "ONNX Runtime init failed: \(ortResult)"))
                    return
                }

                // 2. Create OpenJtalk instance
                let jtalkResult = voicevox_open_jtalk_rc_new((dicPath as NSString).utf8String, &self.openJtalk)
                guard Int32(jtalkResult) == 0 else {
                    cont.resume(throwing: TTSError.synthesisFailed(reason: "OpenJtalk init failed: \(jtalkResult)"))
                    return
                }

                // 3. Create Synthesizer
                let options = voicevox_make_default_initialize_options()
                let synResult = voicevox_synthesizer_new(self.onnxRuntime, self.openJtalk, options, &self.synthesizer)
                
                if Int32(synResult) == 0 {
                    self.isReady = true
                    print("[VoiceVox] Engine 0.16.4 initialized successfully.")
                    cont.resume()
                } else {
                    cont.resume(throwing: TTSError.synthesisFailed(reason: "Synthesizer creation failed: \(synResult)"))
                }
            }
        }
    }

    /// Loads a .vvm model file into the synthesizer.
    func loadModel(at path: String) async throws {
        guard isReady else { throw TTSError.notInitialized }
        print("[VoiceVox] Loading model file: \(path)")
        
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                var modelFile: OpaquePointer?
                let openResult = voicevox_voice_model_file_open((path as NSString).utf8String, &modelFile)
                
                guard Int32(openResult) == 0, let file = modelFile else {
                    print("[VoiceVox] ERROR: voicevox_voice_model_file_open failed: \(openResult)")
                    cont.resume(throwing: TTSError.modelNotLoaded)
                    return
                }
                
                let loadResult = voicevox_synthesizer_load_voice_model(self.synthesizer, file)
                
                if Int32(loadResult) == 0 {
                    print("[VoiceVox] SUCCESS: Model loaded into synthesizer.")
                    // Keep the file handle alive! Deleting it here would invalidate the model data.
                    self.modelHandles[path] = file
                    cont.resume()
                } else {
                    print("[VoiceVox] ERROR: voicevox_synthesizer_load_voice_model failed: \(loadResult)")
                    voicevox_voice_model_file_delete(file)
                    cont.resume(throwing: TTSError.synthesisFailed(reason: "Model load failed: \(loadResult)"))
                }
            }
        }
    }

    func synthesize(text: String, speakerID: Int) async throws -> Data {
        guard isReady else { throw TTSError.notInitialized }
        
        // 1. Map Style ID to Character ID for model loading and get actual internal ID
        let mapping = VoiceVoxSpeaker.map(speakerID)
        let characterID = mapping.filenameID
        let internalStyleID = mapping.internalStyleID
        
        // 2. Ensure model is loaded for this character
        if !loadedModelIDs.contains("\(characterID)") {
            guard let modelPath = VoiceVoxModelAccess.modelURL(forSpeakerID: characterID)?.path else {
                print("[VoiceVox] ERROR: Could not find .vvm for Character ID \(characterID)")
                throw TTSError.modelNotLoaded
            }
            try await loadModel(at: modelPath)
            loadedModelIDs.insert("\(characterID)")
        }
        
        // 3. Synthesize
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                var outputSize: Int = 0
                var outputData: UnsafeMutablePointer<UInt8>?
                
                print("[VoiceVox] Synthesizing with style ID: \(internalStyleID) (Mapped from: \(speakerID))")
                
                let result = voicevox_synthesizer_tts(
                    self.synthesizer,
                    (text as NSString).utf8String,
                    VoicevoxStyleId(internalStyleID),
                    voicevox_make_default_tts_options(),
                    &outputSize,
                    &outputData
                )

                if Int32(result) == 0, let dataPtr = outputData {
                    let data = Data(bytes: dataPtr, count: Int(outputSize))
                    voicevox_wav_free(dataPtr)
                    cont.resume(returning: data)
                } else {
                    print("[VoiceVox] ERROR: Synthesis failed with result code: \(result)")
                    cont.resume(throwing: TTSError.synthesisFailed(reason: "Synthesis failed with code \(result)"))
                }
            }
        }
    }

    func shutdown() {
        queue.sync {
            if isReady {
                if let syn = synthesizer {
                    voicevox_synthesizer_delete(syn)
                    synthesizer = nil
                }
                if let jtalk = openJtalk {
                    voicevox_open_jtalk_rc_delete(jtalk)
                    openJtalk = nil
                }
                
                // Clean up all loaded models
                for handle in modelHandles.values {
                    voicevox_voice_model_file_delete(handle)
                }
                modelHandles.removeAll()
                loadedModelIDs.removeAll()
                
                isReady = false
                print("[VoiceVox] Engine shutdown.")
            }
        }
    }
}
