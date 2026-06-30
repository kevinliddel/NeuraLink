//
//  LocalWhisperManager.swift
//  NeuraLink
//
//  Local speech-to-text via whisper.cpp (ggml-base), replacing WhisperKit.
//  Why the switch:
//    • Multilingual — ggml-base transcribes Japanese; the old
//      `openai_whisper-tiny.en` was English-only and could not handle JP
//      personas at all.
//    • Lighter — drops the WhisperKit / ArgmaxCore / CoreML+ANE stack.
//    • CPU encoder — on A13 whisper.cpp's Metal encoder produces garbage
//      (no simdgroup-matrix HW), and keeping STT on the CPU avoids competing
//      with the VRM avatar + llama.cpp for the Metal GPU. (Matches the old
//      WhisperKit `cpuOnly` setting, so no speed regression.)
//
//  Pipeline: VAD endpoints the utterance → LocalLLMManager+VAD converts to
//  16 kHz mono float → transcribe(samples:) feeds those floats straight to
//  whisper.cpp (no WAV round-trip) → didTranscribeText. One-shot at voice-end;
//  the model stays resident after first load.
//
//  Created by Dedicatus on 23/04/2026.
//

import Foundation

/// A protocol to receive transcriptions from the local STT engine.
protocol LocalWhisperManagerDelegate: AnyObject {
    func whisperManager(didTranscribePartialText text: String)
    func whisperManager(didTranscribeText text: String)
    func whisperManager(didFailWithError error: Error)
}

/// Manages local Speech-to-Text inference via whisper.cpp.
final class LocalWhisperManager: NSObject, @unchecked Sendable {
    static let shared = LocalWhisperManager()

    weak var delegate: LocalWhisperManagerDelegate?

    /// Whisper context (`WhisperBridge*`). Touched only on `queue`.
    private var handle: OpaquePointer?
    private var isReady = false
    private var setupTask: Task<Bool, Never>?
    // Guards the setupTask check-and-create so concurrent callers can't both see nil.
    private let setupLock = NSLock()
    /// Serializes all whisper.cpp calls — `whisper_context` is not safe for
    /// concurrent `whisper_full`, and load/transcribe/free must not overlap.
    private let queue = DispatchQueue(label: "com.neuralink.whisper", qos: .userInitiated)

    /// A13 P-core count; matches the LLM profile's thread strategy. whisper-base
    /// transcribes a short utterance in ~1–2 s on CPU at this width.
    private static let threads: Int32 = 2
    /// GGML model filename (bundled or downloaded). Multilingual base model.
    private static let modelFileName = "ggml-base"
    /// Max transcript bytes per utterance — ample for a spoken sentence.
    private static let outputBufferBytes = 4096

    /// One-shot migration flag: pre-Phase-4 builds wrote raw user audio to
    /// `Documents/whisper_<ts>.wav`; sweep any backlog once. (The whisper.cpp
    /// path never writes WAVs — it feeds float samples directly.)
    private static let legacyDocsCleanupFlag = "com.neuralink.migration.whisperDocsCleanup.v1"

    override private init() {
        super.init()
        Self.sweepLegacyDocumentsAudioIfNeeded()
    }

    var isReadyToUse: Bool { isReady }

    // MARK: - Setup

    /// Loads the whisper.cpp model once and keeps it resident. Concurrent
    /// callers share one Task.
    @discardableResult
    func setup() async -> Bool {
        if isReady { return true }

        #if DEBUG
        // Debug harness (`-nl.debug.skipWhisper YES`): report "ready" WITHOUT
        // loading the model, so STT consumes no memory. Pairs with the canned
        // turn auto-fired in startListening to drive the LLM without speech.
        // transcribe() no-ops while skipped (handle stays nil).
        if UserDefaults.standard.bool(forKey: "nl.debug.skipWhisper") {
            nlLog("[Whisper] DEBUG nl.debug.skipWhisper=YES — NOT loading whisper.cpp.", level: .info)
            return true
        }
        #endif

        let task: Task<Bool, Never> = setupLock.withLock {
            if let existing = setupTask { return existing }
            let t = Task<Bool, Never> {
                let modelPath: String
                do {
                    // Resolves bundle → <App Support>/hf-assets/stt/whisper/
                    // ggml-base.bin → first-launch HTTPS download from the
                    // public HF dataset. ~141 MB, so it can't live in git.
                    modelPath = try await RemoteAssetCache.shared.url(for: .whisperModel).path
                } catch {
                    nlLog(
                        "[Whisper] ggml-base.bin unavailable (bundle/cache/download failed: \(error)). STT disabled.",
                        level: .error)
                    self.setupLock.withLock { self.setupTask = nil }
                    return false
                }
                return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    self.queue.async {
                        // use_gpu = false: A13 Metal whisper is broken, and CPU
                        // keeps STT off the avatar/LLM-contended GPU.
                        let h = whisper_bridge_create(modelPath, false, Self.threads)
                        guard let h else {
                            nlLog("[Whisper] whisper_bridge_create failed for \(modelPath)", level: .error)
                            self.setupLock.withLock { self.setupTask = nil }
                            cont.resume(returning: false)
                            return
                        }
                        self.handle = h
                        self.isReady = true
                        nlLog(
                            "[Whisper] whisper.cpp ready (\(Self.modelFileName), CPU, \(Self.threads) threads).",
                            level: .info)
                        cont.resume(returning: true)
                    }
                }
            }
            setupTask = t
            return t
        }
        return await task.value
    }

    /// Frees the model and releases its memory. Safe to call when unloading.
    ///
    /// Also used to reclaim RAM *during* LLM decode on the 4 GB tier (freed at
    /// generation start, reloaded at generation end — see LocalLLMManager).
    /// Clears `setupTask` + `isReady` synchronously so a later `setup()`
    /// actually reloads instead of short-circuiting on the stale completed task
    /// and returning `true` with a freed/nil handle.
    func shutdown() {
        setupLock.withLock { setupTask = nil }
        isReady = false
        queue.async { [weak self] in
            guard let self, let h = self.handle else { return }
            whisper_bridge_free(h)
            self.handle = nil
            nlLog("[Whisper] whisper.cpp context freed.", level: .info)
        }
    }

    // MARK: - Transcription

    /// Transcribes 16 kHz mono float PCM. `isPartial` is honoured for API
    /// compatibility but ignored: this engine is one-shot at voice-end, so
    /// partial (mid-utterance) requests are dropped — re-transcribing a growing
    /// buffer on CPU is wasteful and the live caption is not worth it here.
    func transcribe(samples: [Float], isPartial: Bool = false) async {
        if isPartial { return }
        guard !samples.isEmpty else { return }

        // 1. Remove DC offset (centre the signal).
        let mean = samples.reduce(0, +) / Float(samples.count)
        let centered = samples.map { $0 - mean }

        // 2. Peak amplitude — gate out room noise (VAD false positives) and
        //    normalise quiet speech.
        let maxAmp = centered.reduce(0) { max($0, abs($1)) }
        nlLog(
            "[Whisper] Samples: \(samples.count), maxAmp: \(String(format: "%.4f", maxAmp)), DC Offset: \(String(format: "%.4f", mean))",
            level: .info)

        // Real speech at arm's length peaks above 0.05; below that it's silence
        // or ambient noise — amplifying it only feeds loud noise to the encoder.
        guard maxAmp >= 0.05 else {
            nlLog(
                "[Whisper] Skipping: maxAmp \(String(format: "%.4f", maxAmp)) below speech threshold.",
                level: .info)
            return
        }

        var normalized = centered
        if maxAmp < 0.3 {
            let gain = Float(0.3) / maxAmp
            normalized = centered.map { $0 * gain }
            nlLog("[Whisper] Normalized: gain \(String(format: "%.2f", gain))×", level: .info)
        }

        let language = await MainActor.run { Self.currentLanguage() }

        // Self-heal: the 4 GB decode-window optimization frees the model during
        // LLM generation (see LocalLLMManager) and reloads it at generation end.
        // If an error path skipped that reload, load now so a real utterance is
        // never dropped. No-op (returns immediately) when already loaded.
        if !isReadyToUse { _ = await setup() }

        let text: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async { [weak self] in
                guard let self, let handle = self.handle else {
                    nlLog("[Whisper] whisper.cpp not ready.", level: .info)
                    cont.resume(returning: nil)
                    return
                }
                var out = [CChar](repeating: 0, count: Self.outputBufferBytes)
                let n: Int32 = normalized.withUnsafeBufferPointer { p in
                    whisper_bridge_transcribe(
                        handle, p.baseAddress, Int32(normalized.count),
                        language, &out, Int32(out.count))
                }
                if n < 0 {
                    nlLog("[Whisper] whisper_bridge_transcribe failed (code \(n)).", level: .error)
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: String(cString: out))
            }
        }

        guard let fullText = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !fullText.isEmpty
        else {
            nlLog("[Whisper] Transcription empty (silence or noise).", level: .info)
            return
        }

        nlLog("[Whisper] Transcription complete (\(fullText.count) chars, lang=\(language)).", level: .info)
        nlLogSensitive("[Whisper] Transcription text: \(fullText)", level: .info)
        await MainActor.run { [weak self] in
            self?.delegate?.whisperManager(didTranscribeText: fullText)
        }
    }

    /// ISO language for whisper: explicit `ja` for the Japanese model slot,
    /// `en` otherwise. Explicit beats auto-detect on short utterances.
    @MainActor
    private static func currentLanguage() -> String {
        LocalModelDownloadManager.shared.selectedConfig == .japaneseGemma2b ? "ja" : "en"
    }

    // MARK: - Legacy cleanup

    /// Deletes any `whisper_*.wav` left in Documents by pre-Phase-4 builds.
    /// Guarded by a UserDefaults flag so it runs at most once per install.
    private static func sweepLegacyDocumentsAudioIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyDocsCleanupFlag) else { return }

        let fileManager = FileManager.default
        guard let docs = fileManager.urls(
            for: .documentDirectory, in: .userDomainMask).first
        else {
            defaults.set(true, forKey: legacyDocsCleanupFlag)
            return
        }

        var removed = 0
        if let contents = try? fileManager.contentsOfDirectory(atPath: docs.path) {
            for name in contents where name.hasPrefix("whisper_") && name.hasSuffix(".wav") {
                let url = docs.appendingPathComponent(name)
                do {
                    try fileManager.removeItem(at: url)
                    removed += 1
                } catch {
                    nlLog(
                        "[Whisper] Legacy sweep: failed to remove \(name): \(error)",
                        level: .warning)
                }
            }
        }

        if removed > 0 {
            nlLog(
                "[Whisper] Legacy sweep: removed \(removed) pre-Phase-4 whisper_*.wav from Documents/",
                level: .info)
        }
        defaults.set(true, forKey: legacyDocsCleanupFlag)
    }
}
