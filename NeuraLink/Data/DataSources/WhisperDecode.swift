//
//  WhisperDecode.swift
//  NeuraLink
//
//  One whisper.cpp decode, shared by LocalWhisperManager and
//  WhisperPhantomDiagnostic: the same level gate, normalisation and decode
//  settings.
//
//  Whisper was trained on subtitles, so on silence, breath or room noise it
//  writes what subtitles say there: "(笑)", "(音楽)", "(エンディング)",
//  "[MUSIC]". Those annotations are easy to recognise, so they are left on
//  and dropped later (PhantomTranscriptFilter). Suppressing them in the
//  decoder was measured to be worse: whisper then invents believable words
//  for the same noise ("アイス", "I'm going to start the engine.").
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation

nonisolated enum WhisperDecode {
    /// Real speech at arm's length peaks above this; below is silence or room
    /// noise, and amplifying it only feeds loud noise to the encoder.
    static let minPeak: Float = 0.05
    /// Quiet speech is raised to this peak before decoding.
    static let targetPeak: Float = 0.3
    /// Max transcript bytes per utterance — ample for a spoken sentence.
    static let outputBufferBytes = 4096

    /// DC removal and peak normalisation; nil when the clip is too quiet to
    /// hold speech.
    static func prepare(_ samples: [Float]) -> (samples: [Float], peak: Float, gain: Float)? {
        guard !samples.isEmpty else { return nil }
        let mean = samples.reduce(0, +) / Float(samples.count)
        let centered = samples.map { $0 - mean }
        let peak = centered.reduce(0) { max($0, abs($1)) }
        guard peak >= minPeak else { return nil }
        guard peak < targetPeak else { return (centered, peak, 1) }
        let gain = targetPeak / peak
        return (centered.map { $0 * gain }, peak, gain)
    }

    /// Decodes 16 kHz mono PCM into trimmed text. The caller serialises calls
    /// on `handle`.
    static func run(handle: OpaquePointer, samples: [Float], language: String,
                    suppressNonSpeech: Bool = false) -> String? {
        whisper_bridge_set_suppress_non_speech(handle, suppressNonSpeech)
        var out = [CChar](repeating: 0, count: outputBufferBytes)
        let written: Int32 = samples.withUnsafeBufferPointer { pointer in
            whisper_bridge_transcribe(handle, pointer.baseAddress, Int32(samples.count), language, &out, Int32(out.count))
        }
        guard written >= 0 else {
            nlLog("[Whisper] whisper_bridge_transcribe failed (code \(written)).", level: .error)
            return nil
        }
        return String(cString: out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads a model for diagnostics (the app goes through LocalWhisperManager).
    static func load(modelPath: String, threads: Int32 = 2) -> OpaquePointer? {
        whisper_bridge_create(modelPath, false, threads)
    }

    static func free(_ handle: OpaquePointer) {
        whisper_bridge_free(handle)
    }
}
