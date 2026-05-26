//
//  LocalWhisperManager.swift
//  NeuraLink
//
//  Created by Dedicatus on 23/04/2026.
//

import AVFoundation
import CoreML
import Foundation
import WhisperKit

/// A protocol to receive transcriptions from WhisperKit.
protocol LocalWhisperManagerDelegate: AnyObject {
    func whisperManager(didTranscribePartialText text: String)
    func whisperManager(didTranscribeText text: String)
    func whisperManager(didFailWithError error: Error)
}

/// Manages local Speech-to-Text inference utilizing the Apple Neural Engine via WhisperKit.
final class LocalWhisperManager: NSObject, @unchecked Sendable {
    static let shared = LocalWhisperManager()

    weak var delegate: LocalWhisperManagerDelegate?

    private var whisperKit: WhisperKit?
    private var isReady = false
    private var setupTask: Task<Bool, Never>?
    // Guards the setupTask check-and-create so concurrent callers can't both see nil.
    private let setupLock = NSLock()

    // To support iPhone 11 (4GB RAM) efficiently, "openai_whisper-tiny.en" or "tiny.en" is recommended.
    // "openai_whisper-base" and "large-v3-turbo" cause the OS to kill the Metal Compiler (Jetsam)
    // when loaded alongside the Llama LLM due to 4GB RAM limits.
    private let modelName = "openai_whisper-tiny.en"

    /// One-shot migration flag: pre-Phase-4 builds wrote raw user audio
    /// to `Documents/whisper_<ts>.wav` where it persisted indefinitely
    /// and was eligible for iCloud backup. We now write to `tmpDirectory`
    /// and delete after transcribe — but installed users may have a
    /// backlog from the old code path that needs sweeping once.
    private static let legacyDocsCleanupFlag = "com.neuralink.migration.whisperDocsCleanup.v1"

    override private init() {
        super.init()
        Self.sweepLegacyDocumentsAudioIfNeeded()
    }

    /// Deletes any `whisper_*.wav` left in the Documents directory by
    /// pre-Phase-4 builds. Guarded by a UserDefaults flag so it runs at
    /// most once per install. Best-effort — a failure logs but does not
    /// block app launch.
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

    var isReadyToUse: Bool { isReady }

    /// Writes the float PCM samples as a 16 kHz mono WAV inside the app's
    /// `tmpDirectory` and returns the URL — required because
    /// `WhisperKit.transcribe(audioPath:)` reads through `AVAudioFile`,
    /// which handles the Int16 PCM conversion that the `audioArray:` code
    /// path doesn't. Caller is responsible for deleting the file when
    /// transcription completes; the file's location guarantees it never
    /// lands in iCloud / iTunes backups and never appears in Files.app.
    ///
    /// Filename uses a UUID rather than a Unix timestamp so concurrent
    /// transcriptions (e.g. proactive vision overlap) can't collide on
    /// the same path. Protection class is applied for parity with the
    /// rest of the app's on-disk state, even though tmp files are also
    /// purged by the OS on a schedule.
    @discardableResult
    private func writeTranscriptionInputWAV(
        samples: [Float], sampleRate: Double = 16000
    ) -> URL? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let ch = buffer.floatChannelData {
            for (i, s) in samples.enumerated() { ch[0][i] = s }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            try? ProtectedStorage.protect(url)
            nlLog(
                "[Whisper] Transcription input saved → \(url.lastPathComponent) (\(samples.count) samples)",
                level: .info)
            return url
        } catch {
            nlLog("[Whisper] writeTranscriptionInputWAV failed: \(error)", level: .error)
            return nil
        }
    }

    private func precreateDirectories() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileManager = FileManager.default
        
        let paths = [
            docs.appendingPathComponent("huggingface/models/openai/whisper-tiny.en/.cache/huggingface/download"),
            docs.appendingPathComponent("huggingface/models/openai/whisper-tiny.en"),
            docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en/.cache/huggingface/download"),
            docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en")
        ]
        
        for url in paths {
            do {
                if !fileManager.fileExists(atPath: url.path) {
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
                    nlLog("[Whisper] Pre-created directory: \(url.path)", level: .info)
                }
            } catch {
                nlLog("[Whisper] Failed to create directory \(url.path): \(error)", level: .error)
            }
        }
    }

    private func cleanStaleCacheFiles() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileManager = FileManager.default
        let searchDirectories = [
            docs.appendingPathComponent("huggingface/models/openai/whisper-tiny.en/.cache/huggingface/download"),
            docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en/.cache/huggingface/download")
        ]
        
        for dir in searchDirectories {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            do {
                let files = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                for file in files {
                    if file.pathExtension == "incomplete" || file.lastPathComponent.contains("incomplete") {
                        try fileManager.removeItem(at: file)
                        nlLog("[Whisper] Removed stale incomplete file: \(file.lastPathComponent)", level: .info)
                    }
                }
            } catch {
                nlLog("[Whisper] Error cleaning directory \(dir.path): \(error)", level: .info)
            }
        }
    }

    /// Initializes WhisperKit. Concurrent callers share one Task — WhisperKit is only loaded once.
    @discardableResult
    func setup() async -> Bool {
        if isReady { return true }

        // Atomically check-and-create the shared Task so two concurrent callers
        // can't both observe setupTask == nil and each start their own load.
        let task: Task<Bool, Never> = setupLock.withLock {
            if let existing = setupTask { return existing }
            let t = Task<Bool, Never> {
                nlLog("[Whisper] Initializing WhisperKit with recommended model...", level: .info)
                
                // Pre-create directory paths and purge incomplete download caches
                // to prevent Cocoa move error code 4 / POSIX file missing error code 2.
                self.precreateDirectories()
                self.cleanStaleCacheFiles()
                
                do {
                    // GPU encoder competes with the Metal VRM renderer and triggers Cast-op
                    // timeouts on the shared command buffer. CPU-only encoder is stable.
                    let computeOptions = ModelComputeOptions(
                        audioEncoderCompute: .cpuOnly,
                        textDecoderCompute: .cpuOnly
                    )
                    self.whisperKit = try await WhisperKit(
                        model: self.modelName, computeOptions: computeOptions)
                    self.isReady = true
                    nlLog("[Whisper] WhisperKit initialized successfully.", level: .info)
                    return true
                } catch {
                    nlLog("[Whisper] Failed to initialize WhisperKit: \(error)", level: .error)
                    self.setupLock.withLock {
                        self.setupTask = nil
                    }
                    return false
                }
            }
            setupTask = t
            return t
        }
        return await task.value
    }

    /// Transcribes raw PCM float samples captured natively.
    /// - Parameters:
    ///   - samples: PCM Float samples
    ///   - isPartial: If true, notifies the delegate as a partial transcription for streaming.
    func transcribe(samples: [Float], isPartial: Bool = false) async {
        guard isReady, let whisper = whisperKit else {
            nlLog("[Whisper] WhisperKit not ready.", level: .info)
            return
        }

        do {
            // 1. Remove DC Offset (Center the signal)
            let mean = samples.reduce(0, +) / Float(samples.count)
            let centeredSamples = samples.map { $0 - mean }

            // 2. Normalize amplitude to 0.5 to prevent Float16 quantization loss in the CPU log-mel encoder
            let maxAmp = centeredSamples.reduce(0) { max($0, abs($1)) }
            nlLog(
                "[Whisper] Samples: \(samples.count), maxAmp: \(String(format: "%.4f", maxAmp)), DC Offset: \(String(format: "%.4f", mean))",
                level: .info)

            // Reject clips that are almost certainly room noise (VAD false-positive).
            // Real speech at arm's length from an iPhone mic peaks above 0.05; below
            // that the clip is either silence or ambient noise and amplifying it only
            // sends loud noise to the Whisper encoder.
            guard maxAmp >= 0.05 else {
                nlLog(
                    "[Whisper] Skipping: maxAmp \(String(format: "%.4f", maxAmp)) below speech threshold.",
                    level: .info)
                return
            }

            var normalizedSamples = centeredSamples
            if maxAmp < 0.3 {
                let gain = Float(0.3) / maxAmp
                normalizedSamples = centeredSamples.map { $0 * gain }
                nlLog("[Whisper] Normalized: gain \(String(format: "%.2f", gain))×", level: .info)
            }

            // Save to WAV so WhisperKit can load via its own audio pipeline.
            // transcribe(audioPath:) uses AVAudioFile internally which handles
            // Int16 PCM conversion — a different code path from transcribe(audioArray:).
            // File lives in tmpDirectory (not Documents/) so it never enters
            // iCloud backups or Files.app, and we delete it the moment
            // transcription returns so it isn't sitting on disk between turns.
            guard let audioURL = writeTranscriptionInputWAV(samples: normalizedSamples) else {
                nlLog("[Whisper] Could not save audio for transcription.", level: .info)
                return
            }
            defer { try? FileManager.default.removeItem(at: audioURL) }

            var options = DecodingOptions()
            options.noSpeechThreshold = 0.6
            options.withoutTimestamps = true
            options.firstTokenLogProbThreshold = nil
            options.compressionRatioThreshold = nil
            options.temperature = 0.2
            options.temperatureFallbackCount = 3
            options.temperatureIncrementOnFallback = 0.2

            let result = try await whisper.transcribe(
                audioPath: audioURL.path, decodeOptions: options)

            let allSegments = result.flatMap { $0.segments }
            for (i, seg) in allSegments.enumerated() {
                // Metadata public, segment text private — keeps confidence
                // diagnostics visible without leaking the spoken content.
                nlLog(
                    "[Whisper] Segment[\(i)]: noSpeechProb=\(String(format: "%.3f", seg.noSpeechProb)) avgLogprob=\(String(format: "%.3f", seg.avgLogprob)) temp=\(seg.temperature)",
                    level: .info)
                nlLogSensitive("[Whisper] Segment[\(i)] text: '\(seg.text)'", level: .info)
            }

            let fullText = result.map { $0.text }.joined(separator: " ").trimmingCharacters(
                in: .whitespacesAndNewlines)

            if !fullText.isEmpty {
                nlLog("[Whisper] Transcription complete (partial=\(isPartial), \(fullText.count) chars)", level: .info)
                nlLogSensitive("[Whisper] Transcription text: \(fullText)", level: .info)
                DispatchQueue.main.async { [weak self] in
                    if isPartial {
                        self?.delegate?.whisperManager(didTranscribePartialText: fullText)
                    } else {
                        self?.delegate?.whisperManager(didTranscribeText: fullText)
                    }
                }
            } else {
                nlLog("[Whisper] Transcription resulted in empty text (likely silence or noise).", level: .info)
            }

        } catch {
            nlLog("[Whisper] Transcription error: \(error)", level: .error)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.whisperManager(didFailWithError: error)
            }
        }
    }
}
