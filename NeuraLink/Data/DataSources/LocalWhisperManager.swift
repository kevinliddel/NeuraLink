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
    // WhisperKit downloads the optimized CoreML model on initialization if missing.
    private let modelName = "openai_whisper-tiny.en"

    override private init() {
        super.init()
    }

    var isReadyToUse: Bool { isReady }

    // Writes samples as a 16 kHz mono PCM-float WAV. Returns the URL for transcription.
    // Pull files from Documents via Xcode → Window → Devices → NeuraLink → Download Container.
    @discardableResult
    private func saveDebugAudio(samples: [Float], sampleRate: Double = 16000) -> URL? {
        guard
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
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

        let stamp = Int(Date().timeIntervalSince1970)
        let url = docs.appendingPathComponent("whisper_\(stamp).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            print(
                "[Whisper] Debug audio saved → \(url.lastPathComponent) (\(samples.count) samples)")
            return url
        } catch {
            print("[Whisper] saveDebugAudio failed: \(error)")
            return nil
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
                print("[Whisper] Initializing WhisperKit with recommended model...")
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
                    print("[Whisper] WhisperKit initialized successfully.")
                    return true
                } catch {
                    print("[Whisper] Failed to initialize WhisperKit: \(error)")
                    return false
                }
            }
            setupTask = t
            return t
        }
        return await task.value
    }

    /// Transcribes raw PCM float samples captured natively.
    func transcribe(samples: [Float]) async {
        guard isReady, let whisper = whisperKit else {
            print("[Whisper] WhisperKit not ready.")
            return
        }

        do {
            // 1. Remove DC Offset (Center the signal)
            let mean = samples.reduce(0, +) / Float(samples.count)
            let centeredSamples = samples.map { $0 - mean }

            // 2. Normalize amplitude to 0.5 to prevent Float16 quantization loss in the CPU log-mel encoder
            let maxAmp = centeredSamples.reduce(0) { max($0, abs($1)) }
            print(
                "[Whisper] Samples: \(samples.count), maxAmp: \(String(format: "%.4f", maxAmp)), DC Offset: \(String(format: "%.4f", mean))"
            )

            // Reject clips that are almost certainly room noise (VAD false-positive).
            // Real speech at arm's length from an iPhone mic peaks above 0.05; below
            // that the clip is either silence or ambient noise and amplifying it only
            // sends loud noise to the Whisper encoder.
            guard maxAmp >= 0.05 else {
                print(
                    "[Whisper] Skipping: maxAmp \(String(format: "%.4f", maxAmp)) below speech threshold."
                )
                return
            }

            var normalizedSamples = centeredSamples
            if maxAmp < 0.3 {
                let gain = Float(0.3) / maxAmp
                normalizedSamples = centeredSamples.map { $0 * gain }
                print("[Whisper] Normalized: gain \(String(format: "%.2f", gain))×")
            }

            // Save to WAV so WhisperKit can load via its own audio pipeline.
            // transcribe(audioPath:) uses AVAudioFile internally which handles
            // Int16 PCM conversion — a different code path from transcribe(audioArray:).
            guard let audioURL = saveDebugAudio(samples: normalizedSamples) else {
                print("[Whisper] Could not save audio for transcription.")
                return
            }

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
                print(
                    "[Whisper] Segment[\(i)]: '\(seg.text)' noSpeechProb=\(String(format: "%.3f", seg.noSpeechProb)) avgLogprob=\(String(format: "%.3f", seg.avgLogprob)) temp=\(seg.temperature)"
                )
            }

            let fullText = result.map { $0.text }.joined(separator: " ").trimmingCharacters(
                in: .whitespacesAndNewlines)

            if !fullText.isEmpty {
                print("[Whisper] Transcription complete: \(fullText)")
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.whisperManager(didTranscribeText: fullText)
                }
            } else {
                print("[Whisper] Transcription resulted in empty text (likely silence or noise).")
            }

        } catch {
            print("[Whisper] Transcription error: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.whisperManager(didFailWithError: error)
            }
        }
    }
}
