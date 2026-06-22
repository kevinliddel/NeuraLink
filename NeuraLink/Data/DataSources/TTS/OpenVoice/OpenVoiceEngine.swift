//
//  OpenVoiceEngine.swift
//  NeuraLink
//
//  TTSEngineProtocol implementation over the `openvoice_bridge` C bridge
//  (MeloTTS + tone-color converter, ONNX). The local TTS for every
//  non-Japanese voice (VoiceVox stays for the JP model).
//
//  text -> G2P -> chunk at punctuation -> openvoice_bridge_say per chunk
//  (22.05 kHz mono float) -> AVAudioPCMBuffer -> onBufferReady. Unlike
//  SynapLink's VoiceCloner, this engine does NOT own an AVAudioEngine: it
//  pushes buffers through `onBufferReady` and LocalLLMManager+TTS schedules
//  playback (matching VoiceVox/Kokoro).
//
//  Ported from SynapLink's VoiceCloner (synth / chunkize / trimSilence).
//

import AVFoundation
import Foundation

final class OpenVoiceEngine: NSObject, @unchecked Sendable, TTSEngineProtocol {

    static let shared = OpenVoiceEngine()

    // MARK: - TTSEngineProtocol

    private(set) var isReady = false
    var onBufferReady: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - Internals

    private let queue = DispatchQueue(label: "com.neuralink.openvoice.engine", qos: .userInitiated)
    private var initTask: Task<Void, Error>?
    private let initLock = NSLock()
    private var handle: OpaquePointer?          // OpenVoiceBridge*
    private var g2p: G2P?
    private var sourceSE: [Float] = []
    private var seCache: [String: [Float]] = [:]
    private let sampleRate = Double(openvoice_bridge_sample_rate())  // 22050

    // Sentence chunking — group whole sentences into ~minChunkChars…maxChunkChars
    // so MeloTTS+BERT get full sentences (good intonation) while no tiny chunk
    // starves the player. Mirrors VoiceCloner.
    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let minChunkChars = 60
    private static let maxChunkChars = 220
    private static let pauseMap: [Character: Double] = [
        ",": 0.05, ";": 0.06, ":": 0.06, ".": 0.12, "!": 0.12, "?": 0.12
    ]

    override private init() { super.init() }

    deinit { shutdown() }

    // MARK: - Lifecycle

    func initialize() async throws {
        if isReady { return }
        // Concurrent speakChunk() callers must all AWAIT the same init — the
        // first-run download + loading 376 MB of ONNX takes seconds, and an
        // early-return on an in-flight init makes their speak() throw
        // .notInitialized. Share one Task; everyone awaits it.
        let task: Task<Void, Error> = initLock.withLock {
            if let existing = initTask { return existing }
            let t = Task<Void, Error> { try await self.performInitialize() }
            initTask = t
            return t
        }
        do {
            try await task.value
        } catch {
            initLock.withLock { initTask = nil }  // let a later call retry
            throw error
        }
    }

    private func performInitialize() async throws {
        nlLog("[OpenVoice] Resolving models (first run downloads ~285–376 MB from HF; then loads ONNX)…", level: .info)

        // Resolve the big ONNX models (downloads on first run; instant if cached).
        let meloURL: URL
        let convURL: URL
        do {
            meloURL = try await OpenVoiceModelAccess.meloModel()
            convURL = try await OpenVoiceModelAccess.converterModel()
        } catch {
            nlLog("[OpenVoice] Model resolve failed: \(error)", level: .warning)
            throw TTSError.modelNotFound
        }
        // Prosody BERT costs ~91 MB resident + a 91 MB download. On the 4 GB
        // tier that tips the jetsam ceiling (LLM + avatar + melo + converter
        // already crowd it), so skip it there — the voice still works, just
        // with flatter intonation. Loaded only where there's headroom (6 GB+).
        let bertURL = Self.useBertProsody ? await OpenVoiceModelAccess.bertModel() : nil

        // Bundled G2P front-end + base source speaker embedding (required).
        guard let g2p = G2P() else {
            throw TTSError.initializationFailed(reason: "G2P assets (g2p_*/bert_vocab) missing from bundle")
        }
        guard let srcURL = OpenVoiceModelAccess.sourceSE, let src = Self.loadF32(srcURL) else {
            throw TTSError.initializationFailed(reason: "se_source_en.f32 missing from bundle")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                nlLog("[OpenVoice] Initializing bridge: melo=\(meloURL.lastPathComponent), conv=\(convURL.lastPathComponent), bert=\(bertURL?.lastPathComponent ?? "none")", level: .info)
                guard let h = openvoice_bridge_create(meloURL.path, convURL.path, bertURL?.path) else {
                    cont.resume(throwing: TTSError.initializationFailed(reason: "openvoice_bridge_create failed"))
                    return
                }
                self.handle = h
                self.g2p = g2p
                self.sourceSE = src
                self.isReady = true
                nlLog("[OpenVoice] Engine initialized (sr=\(Int(self.sampleRate)), bert=\(bertURL != nil)).", level: .info)
                cont.resume()
            }
        }
    }

    func shutdown() {
        queue.sync {
            guard let h = handle else { isReady = false; return }
            openvoice_bridge_free(h)
            handle = nil
            isReady = false
            nlLog("[OpenVoice] Engine shutdown.", level: .info)
        }
    }

    func stop() {
        // Synthesis runs synchronously on `queue`; cancellation/playback is
        // owned by LocalLLMManager's audio player node (same as Kokoro).
    }

    // MARK: - TTSEngineProtocol.speak

    func speak(_ text: String, persona: PersonaIdentifier) async throws {
        guard isReady, let handle, let g2p else { throw TTSError.notInitialized }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        let voice = Self.voiceName(for: persona)
        guard let tgt = targetSE(voice) else {
            throw TTSError.unsupportedPersona(persona)
        }
        let chunks = Self.chunkize(clean)
        guard !chunks.isEmpty else { return }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                for chunk in chunks {
                    let enc = g2p.encode(chunk.text)
                    guard let audio = self.synth(handle: handle, enc: enc, tgt: tgt) else { continue }
                    var trimmed = Self.trimSilence(audio)
                    guard !trimmed.isEmpty else { continue }
                    if chunk.pause > 0 {
                        trimmed.append(contentsOf: repeatElement(0, count: Int(chunk.pause * self.sampleRate)))
                    }
                    nlLog("[OpenVoice] chunk: raw=\(audio.count) trimmed=\(trimmed.count) sr=\(Int(self.sampleRate))", level: .info)
                    if let pcm = AudioDataConverter.toPCMBuffer(samples: trimmed, sampleRate: self.sampleRate) {
                        self.onBufferReady?(pcm)
                    } else {
                        nlLog("[OpenVoice] toPCMBuffer returned nil — samples=\(trimmed.count) sr=\(self.sampleRate)", level: .error)
                    }
                }
                cont.resume()
            }
        }
    }

    // MARK: - Synthesis (one chunk via the C bridge)

    private func synth(handle: OpaquePointer, enc: G2P.Encoded, tgt: [Float]) -> [Float]? {
        var out: UnsafeMutablePointer<Float>?
        var stage = [Double](repeating: 0, count: 4)  // bert, melo, spec, conv
        let n = enc.phones.withUnsafeBufferPointer { p in
            enc.tones.withUnsafeBufferPointer { t in
                enc.langs.withUnsafeBufferPointer { l in
                    sourceSE.withUnsafeBufferPointer { s in
                        tgt.withUnsafeBufferPointer { g in
                            enc.inputIds.withUnsafeBufferPointer { ids in
                                enc.word2ph.withUnsafeBufferPointer { w2p in
                                    stage.withUnsafeMutableBufferPointer { sm in
                                        openvoice_bridge_say(
                                            handle, p.baseAddress, t.baseAddress, l.baseAddress,
                                            Int32(enc.phones.count), 0, s.baseAddress, g.baseAddress,
                                            ids.baseAddress, w2p.baseAddress, Int32(enc.inputIds.count),
                                            &out, sm.baseAddress)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard n > 0, let out else { return nil }
        defer { openvoice_bridge_free_audio(out) }
        return Array(UnsafeBufferPointer(start: out, count: Int(n)))
    }

    // MARK: - Voice / embedding resolution

    /// Persona → target-voice embedding name, from the user's PersonaSettings
    /// pick (PersonaVoiceStore) else the built-in default. The available voices
    /// (OpenVoiceVoicePreset) are placeholders until NeuraLink persona voices
    /// are extracted offline and bundled/hosted.
    private static func voiceName(for persona: PersonaIdentifier) -> String {
        OpenVoiceVoicePreset.preset(for: persona).identifier
    }

    private func targetSE(_ name: String) -> [Float]? {
        if let cached = seCache[name] { return cached }
        guard let url = OpenVoiceModelAccess.targetSE(named: name), let se = Self.loadF32(url) else {
            return nil
        }
        seCache[name] = se
        return se
    }

    /// Prosody BERT (~91 MB) is only loaded where there's RAM headroom (6 GB+).
    /// On the 4 GB tier it tips the jetsam ceiling alongside the LLM + avatar.
    private static var useBertProsody: Bool {
        ProcessInfo.processInfo.physicalMemory >= 5 * 1024 * 1024 * 1024
    }

    private static func loadF32(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Chunking / trimming (ported from VoiceCloner)

    private struct Chunk { let text: String; let pause: Double }

    /// MeloTTS pads every chunk with leading + trailing near-silence; trim both
    /// ends to the audible region (+ margin) so the pauseMap gap is the only
    /// inter-chunk silence. Empty if all silence.
    private static func trimSilence(_ audio: [Float], threshold: Float = 0.015,
                                    margin: Int = 160) -> [Float] {
        guard let first = audio.firstIndex(where: { abs($0) > threshold }),
              let last = audio.lastIndex(where: { abs($0) > threshold }) else { return [] }
        let start = max(0, first - margin)
        let end = min(audio.count, last + margin + 1)
        return Array(audio[start..<end])
    }

    private static func chunkize(_ text: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var buf = ""
        func flush(_ pause: Double) {
            let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 1 { chunks.append(Chunk(text: trimmed, pause: pause)) }
            buf = ""
        }
        for ch in text {
            buf.append(ch)
            if sentenceEnders.contains(ch) {
                if buf.trimmingCharacters(in: .whitespacesAndNewlines).count >= minChunkChars {
                    flush(pauseMap[ch] ?? 0.12)
                }
            } else if buf.count >= maxChunkChars, ch == "," || ch == ";" || ch == " " {
                flush(pauseMap[ch] ?? 0.05)
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(Chunk(text: tail, pause: 0)) }
        return chunks
    }
}
