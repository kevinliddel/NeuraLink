//
//  WhisperPhantomDiagnostic.swift
//  NeuraLinkTests
//
//  Runs the bundled ggml-base model on what the mic hears between words
//  (noise, a breath, a desk thump, mains hum) and on real speech, with
//  non-speech suppression off and on, and writes what whisper heard and
//  whether PhantomTranscriptFilter drops it. It is why suppression stays off:
//  off, noise comes out as an annotation the filter drops; on, it comes out
//  as believable words.
//
//  Set NL_LLM_DIAG_DIR (report folder) and NL_STT_AUDIO_DIR (16 kHz mono
//  WAVs, e.g. from `say` + `afconvert`) to run.
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation
import Testing
@testable import NeuraLink

@Suite("Whisper phantom diagnostic", .serialized)
struct WhisperPhantomDiagnostic {

    @Test("Whisper on noise vs speech, suppression off and on, when NL_LLM_DIAG_DIR is set")
    func report() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["NL_LLM_DIAG_DIR"],
              let model = Bundle.main.path(forResource: "ggml-base", ofType: "bin"),
              let handle = WhisperDecode.load(modelPath: model, threads: 4)
        else { return }
        defer { WhisperDecode.free(handle) }

        var cases = Self.noiseCases()
        if let audioDir = env["NL_STT_AUDIO_DIR"] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: audioDir)) ?? []
            for file in files.sorted() where file.hasSuffix(".wav") {
                let url = URL(fileURLWithPath: audioDir).appendingPathComponent(file)
                guard let decoded = WAVDecoder.decode(try Data(contentsOf: url)) else { continue }
                cases.append(("speech \(file)", decoded.samples))
                // The same words spoken quietly, as from across the room.
                let peak = decoded.samples.reduce(0) { max($0, abs($1)) }
                if peak > 0 { cases.append(("quiet \(file)", decoded.samples.map { $0 * 0.07 / peak })) }
            }
        }

        var report = "| case | lang | suppress | text |\n|---|---|---|---|\n"
        for (name, raw) in cases {
            guard let prepared = WhisperDecode.prepare(raw) else {
                report += "| \(name) | – | – | ⟨below level gate⟩ |\n"
                continue
            }
            for language in ["ja", "en"] {
                for suppress in [false, true] {
                    guard let text = WhisperDecode.run(
                        handle: handle, samples: prepared.samples, language: language, suppressNonSpeech: suppress)
                    else { continue }
                    let verdict = PhantomTranscriptFilter.reason(transcript: text)
                    report += "| \(name) | \(language) | \(suppress ? "on" : "off") | "
                        + (text.isEmpty ? "⟨empty⟩" : text)
                        + (verdict.map { " → dropped (\($0.rawValue))" } ?? "") + " |\n"
                }
            }
        }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try report.write(to: dir.appendingPathComponent("whisper_phantoms.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - What the mic hears between words

    private static let rate = 16_000

    private static func noiseCases() -> [(String, [Float])] {
        var generator = SeededGenerator(seed: 7)
        func noise(_ seconds: Double, peak: Float) -> [Float] {
            (0..<Int(seconds * Double(rate))).map { _ in Float.random(in: -peak...peak, using: &generator) }
        }
        func envelope(_ samples: [Float]) -> [Float] {
            samples.indices.map { index in
                samples[index] * Float(sin(Double.pi * Double(index) / Double(samples.count)))
            }
        }
        func lowPass(_ samples: [Float], width: Int) -> [Float] {
            var out = [Float](repeating: 0, count: samples.count)
            var sum: Float = 0
            for index in samples.indices {
                sum += samples[index]
                if index >= width { sum -= samples[index - width] }
                out[index] = sum / Float(width)
            }
            return out
        }
        let breath = envelope(lowPass(noise(1.2, peak: 0.6), width: 6)).map { $0 * 0.4 }
        let thump: [Float] = (0..<Int(0.8 * Double(rate))).map { index in
            let time = Double(index) / Double(rate)
            return Float(0.25 * exp(-time * 9) * sin(2 * .pi * 80 * time))
        }
        let hum: [Float] = (0..<Int(2.0 * Double(rate))).map { index in
            let time = Double(index) / Double(rate)
            return Float(0.05 * sin(2 * .pi * 50 * time) + 0.02 * sin(2 * .pi * 150 * time))
        }
        return [
            ("room noise 1 s", noise(1.0, peak: 0.06)),
            ("room noise 2.5 s", noise(2.5, peak: 0.06)),
            ("breath", breath),
            ("desk thump", thump + noise(0.4, peak: 0.01)),
            ("mains hum", hum)
        ]
    }
}

/// Deterministic noise so the report is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
