import AVFoundation
import Foundation

/// F5-TTS engine — lazy-loads on first speak(); all heavy work runs detached off the main actor.
///
/// Why detached tasks:
///   • Task { } in a @MainActor context inherits the main actor, so the ODE loop would block the UI.
///   • Task.detached runs on the cooperative thread pool, leaving the main actor free for VAD + UI.
@MainActor
final class F5TTSEngine: TTSProtocol {

    var onBufferReady: ((AVAudioPCMBuffer) -> Void)? {
        didSet { fallback.onBufferReady = onBufferReady }
    }

    private(set) var isReady: Bool = false

    private var f5tts: F5TTS?
    private var characterReferences: [String: (audio: URL, text: String)] = [:]
    private let fallback = SystemTTSEngine()
    private var loadTask: Task<Void, Never>?

    private let voiceFiles: [String: String] = [
        "Ekaterina": "akira.mp3",
        "Sonya": "riko.wav"
    ]

    init() {
        print("[F5-TTS] init — lazy load enabled (models load on first speak)")
    }

    // MARK: - TTSProtocol

    func speak(_ text: String, for characterName: String) {
        // Trigger lazy load on first call — capture paths on @MainActor before the detached task.
        if loadTask == nil {
            let ditPath    = TTSModelAccess.ditModel.path
            let vocabPath  = TTSModelAccess.vocabConfig.path
            let vocoderPath = TTSModelAccess.vocoderModel.path
            let available  = TTSModelAccess.isAvailable
            let voices     = voiceFiles
            print("[F5-TTS] First speak — triggering lazy background model load")
            loadTask = Task.detached(priority: .background) { [weak self] in
                await self?.loadEngineInBackground(
                    ditPath: ditPath, vocabPath: vocabPath,
                    vocoderPath: vocoderPath, isAvailable: available,
                    voiceFiles: voices
                )
            }
        }

        guard isReady, let f5 = f5tts else {
            print("[F5-TTS] Not ready — routing '\(characterName)' to system fallback")
            fallback.speak(text, for: characterName)
            return
        }

        guard let reference = characterReferences[characterName] else {
            print("[F5-TTS] No voice reference for '\(characterName)' — routing to system fallback")
            fallback.speak(text, for: characterName)
            return
        }

        print("[F5-TTS] Zero-shot synthesis for '\(characterName)' (\(text.count) chars)…")

        // Task.detached: ODE runs on cooperative thread pool, not main actor.
        // Capture [weak self] — @MainActor class is implicitly Sendable; avoids
        // capturing non-Sendable SystemTTSEngine or raw closure across the boundary.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let samples = try await f5.generate(
                    text: text,
                    referenceAudioURL: reference.audio,
                    referenceText: reference.text,
                    steps: 8
                )
                print("[F5-TTS] Generation done — \(samples.count) samples")
                if let buffer = AudioDataConverter.toPCMBuffer(samples: samples, sampleRate: 24000) {
                    print("[F5-TTS] PCM buffer ready — frameLength=\(buffer.frameLength)")
                    await MainActor.run { self?.onBufferReady?(buffer) }
                } else {
                    print("[F5-TTS] PCM conversion returned nil — falling back")
                    await MainActor.run { self?.fallback.speak(text, for: characterName) }
                }
            } catch {
                print("[F5-TTS] Synthesis error: \(error) — falling back")
                await MainActor.run { self?.fallback.speak(text, for: characterName) }
            }
        }
    }

    func stop() {
        fallback.stop()
    }

    // MARK: - Background loading (nonisolated — runs off main actor via Task.detached caller)

    private nonisolated func loadEngineInBackground(
        ditPath: String,
        vocabPath: String,
        vocoderPath: String,
        isAvailable: Bool,
        voiceFiles: [String: String]
    ) async {
        print("[F5-TTS] ── loadEngineInBackground: concurrent model load + voice prep")

        async let modelResult = loadModel(
            ditPath: ditPath, vocabPath: vocabPath,
            vocoderPath: vocoderPath, isAvailable: isAvailable)
        async let voicesResult = prepareReferenceVoices(voiceFiles: voiceFiles)

        let model  = await modelResult
        let voices = await voicesResult

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.characterReferences = voices
            if let model {
                self.f5tts = model
                self.isReady = true
                print("[F5-TTS] ── Engine READY. \(voices.count) voice(s): \(voices.keys.sorted())")
            } else {
                print("[F5-TTS] ── Load failed — system fallback active for all speech")
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
            print("[F5-TTS] loadModel: SKIPPED — model files missing")
            print("[F5-TTS]   DIT   : \(FileManager.default.fileExists(atPath: ditPath))")
            print("[F5-TTS]   Vocab : \(FileManager.default.fileExists(atPath: vocabPath))")
            print("[F5-TTS]   Vocos : \(FileManager.default.fileExists(atPath: vocoderPath))")
            return nil
        }
        print("[F5-TTS] loadModel: loading DiT transformer…")
        do {
            let model = try F5TTS.load(
                modelPath: ditPath,
                vocabPath: vocabPath,
                vocoderPath: vocoderPath)
            print("[F5-TTS] loadModel: SUCCESS")
            return model
        } catch {
            print("[F5-TTS] loadModel: FAILED — \(error)")
            return nil
        }
    }

    private nonisolated func prepareReferenceVoices(
        voiceFiles: [String: String]
    ) async -> [String: (audio: URL, text: String)] {
        var result: [String: (audio: URL, text: String)] = [:]
        let fm = FileManager.default

        for (character, fileName) in voiceFiles {
            let nameURL = URL(fileURLWithPath: fileName)
            let resName = nameURL.deletingPathExtension().lastPathComponent
            let resExt  = nameURL.pathExtension

            // Priority 1: app bundle (works on-device and in simulator)
            if let audioURL = Bundle.main.url(forResource: resName, withExtension: resExt) {
                print("[F5-TTS]   [\(character)] found in bundle: \(audioURL.lastPathComponent)")
                // Placeholder — referenceText is accepted by generate() but not consumed
                // in the ODE loop. Avoid calling LocalWhisperManager here: it shares one
                // WhisperKit instance with the VAD/STT pipeline; concurrent transcription
                // causes EXC_BAD_ACCESS inside WhisperKit's internal state.
                result[character] = (audioURL, "Hello.")
                continue
            }

            // Priority 2: dev source tree (Mac simulator / direct Xcode runs)
            let devURL = URL(fileURLWithPath: "/Users/mac/Dedicatus/NeuraLink/TrainingVoice")
                .appendingPathComponent(fileName)
            if fm.fileExists(atPath: devURL.path) {
                print("[F5-TTS]   [\(character)] found at dev path")
                result[character] = (devURL, "Hello.")
                continue
            }

            print("[F5-TTS]   [\(character)] NOT FOUND in bundle or dev path — skipping")
        }

        print("[F5-TTS] prepareReferenceVoices: \(result.count)/\(voiceFiles.count) voices ready")
        return result
    }
}
