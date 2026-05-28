//
//  F5TTSEngine.swift
//  NeuraLink
//
//  F5-TTS zero-shot voice cloning engine. Lifted from feat/voice-cloning at
//  Phase 2a and adapted to the unified TTSEngineProtocol.
//
//  Lazy-loads the heavy DiT + Vocos models on the first `initialize()` or
//  `speak()` call so the engine is cheap to construct even when not used.
//  Synthesis runs off the main actor via the cooperative thread pool — the
//  underlying `F5TTS` type is non-isolated, so `await f5.generate(...)` from
//  this @MainActor class naturally yields the ODE loop off main.
//
//  Failures (model load fail, no reference sample for persona, conversion
//  error, synthesis throws) all delegate to an internal SystemTTSEngine so
//  the user still hears something. The selector therefore does NOT need to
//  fall back when F5 fails — the engine self-recovers.
//
//  Created by Dedicatus on 26/05/2026.
//

import AVFoundation
import Foundation

@MainActor
final class F5TTSEngine: TTSEngineProtocol {

    var onBufferReady: ((AVAudioPCMBuffer) -> Void)? {
        didSet { fallback.onBufferReady = onBufferReady }
    }

    private(set) var isReady: Bool = false

    private var f5tts: F5TTS?
    private var characterReferences: [PersonaIdentifier: (audio: URL, text: String)] = [:]
    private let fallback = SystemTTSEngine()
    private var loadTask: Task<Void, Never>?

    /// Bundled default reference samples, used when no user clone exists in
    /// `CloneSampleStore` for the persona. Lowercase keys match how the engine
    /// indexes `characterReferences`.
    private let bundledVoiceFiles: [PersonaIdentifier: String] = [
        "ekaterina": "akira.mp3",
        "sonya": "riko.wav"
    ]

    init() {
        nlLog("[F5-TTS] init — lazy load enabled (models load on first speak)", level: .info)
    }

    // MARK: - TTSEngineProtocol

    func initialize() async throws {
        kickOffBackgroundLoadIfNeeded()
    }

    func speak(_ text: String, persona: PersonaIdentifier) async throws {
        kickOffBackgroundLoadIfNeeded()

        let key = persona.lowercased()
        guard isReady, let f5 = f5tts, let reference = characterReferences[key] else {
            nlLog(
                "[F5-TTS] Not ready or no reference for '\(persona)' — routing to system fallback",
                level: .info
            )
            try await fallback.speak(text, persona: persona)
            return
        }

        do {
            let samples = try await f5.generate(
                text: text,
                referenceAudioURL: reference.audio,
                referenceText: reference.text,
                steps: 8
            )
            guard let buffer = AudioDataConverter.toPCMBuffer(samples: samples, sampleRate: 24000) else {
                nlLog("[F5-TTS] PCM conversion returned nil — falling back", level: .error)
                try await fallback.speak(text, persona: persona)
                return
            }
            onBufferReady?(buffer)
        } catch {
            nlLog("[F5-TTS] Synthesis error: \(error) — falling back", level: .error)
            try await fallback.speak(text, persona: persona)
        }
    }

    func stop() {
        fallback.stop()
    }

    func shutdown() {
        loadTask?.cancel()
        loadTask = nil
        f5tts = nil
        characterReferences.removeAll()
        isReady = false
        fallback.shutdown()
    }

    // MARK: - Lazy load

    private func kickOffBackgroundLoadIfNeeded() {
        guard loadTask == nil else { return }

        let ditPath     = F5TTSModelAccess.ditModel.path
        let vocabPath   = F5TTSModelAccess.vocabConfig.path
        let vocoderPath = F5TTSModelAccess.vocoderModel.path
        let isAvailable = F5TTSModelAccess.isAvailable
        let bundled     = bundledVoiceFiles
        let userClones  = CloneSampleStore.shared.snapshot()

        nlLog("[F5-TTS] First call — triggering lazy background model load", level: .info)
        loadTask = Task.detached(priority: .background) { [weak self] in
            await self?.loadEngineInBackground(
                ditPath: ditPath,
                vocabPath: vocabPath,
                vocoderPath: vocoderPath,
                isAvailable: isAvailable,
                bundledVoiceFiles: bundled,
                userClones: userClones
            )
        }
    }

    private nonisolated func loadEngineInBackground(
        ditPath: String,
        vocabPath: String,
        vocoderPath: String,
        isAvailable: Bool,
        bundledVoiceFiles: [PersonaIdentifier: String],
        userClones: [PersonaIdentifier: URL]
    ) async {
        async let modelResult = loadModel(
            ditPath: ditPath,
            vocabPath: vocabPath,
            vocoderPath: vocoderPath,
            isAvailable: isAvailable
        )
        async let voicesResult = prepareReferences(
            bundledVoiceFiles: bundledVoiceFiles,
            userClones: userClones
        )

        let model  = await modelResult
        let voices = await voicesResult

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.characterReferences = voices
            if let model {
                self.f5tts = model
                self.isReady = true
                nlLog(
                    "[F5-TTS] Engine READY. \(voices.count) voice(s): \(voices.keys.sorted())",
                    level: .info
                )
            } else {
                nlLog("[F5-TTS] Load failed — system fallback active for all speech", level: .info)
            }
        }
    }

    private nonisolated func loadModel(
        ditPath: String,
        vocabPath: String,
        vocoderPath: String,
        isAvailable: Bool
    ) async -> F5TTS? {
        guard isAvailable else {
            nlLog("[F5-TTS] loadModel: SKIPPED — model files missing", level: .info)
            return nil
        }
        do {
            let model = try F5TTS.load(
                modelPath: ditPath,
                vocabPath: vocabPath,
                vocoderPath: vocoderPath
            )
            return model
        } catch {
            nlLog("[F5-TTS] loadModel: FAILED — \(error)", level: .error)
            return nil
        }
    }

    private nonisolated func prepareReferences(
        bundledVoiceFiles: [PersonaIdentifier: String],
        userClones: [PersonaIdentifier: URL]
    ) async -> [PersonaIdentifier: (audio: URL, text: String)] {
        // Why "Hello.": F5TTS.generate accepts a `referenceText` but the
        // current ODE path doesn't consume it. Calling LocalWhisperManager
        // here is unsafe — it shares one WhisperKit instance with the VAD
        // pipeline and concurrent transcription causes EXC_BAD_ACCESS.
        var result: [PersonaIdentifier: (audio: URL, text: String)] = [:]
        let fm = FileManager.default

        // User-supplied clones take precedence over bundled defaults.
        for (persona, url) in userClones where fm.fileExists(atPath: url.path) {
            result[persona] = (url, "Hello.")
        }

        for (persona, filename) in bundledVoiceFiles where result[persona] == nil {
            let nameURL = URL(fileURLWithPath: filename)
            let resName = nameURL.deletingPathExtension().lastPathComponent
            let resExt  = nameURL.pathExtension

            if let audioURL = Bundle.main.url(forResource: resName, withExtension: resExt) {
                result[persona] = (audioURL, "Hello.")
                continue
            }

            // Development convenience — Phase 5 `TTSAsset` work removes this path.
            let devURL = URL(fileURLWithPath: "/Users/mac/Dedicatus/NeuraLink/TrainingVoice")
                .appendingPathComponent(filename)
            if fm.fileExists(atPath: devURL.path) {
                result[persona] = (devURL, "Hello.")
            }
        }

        return result
    }
}
