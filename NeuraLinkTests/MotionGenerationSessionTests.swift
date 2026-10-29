//
//  MotionGenerationSessionTests.swift
//  NeuraLinkTests
//
//  The Swift runtime against the Python driver's two-window fixture for
//  "A person waves with the right hand." seed 1: the noise source, the
//  WordPiece ids, the recentering and requantization are checked without
//  any model; with NL_MOTION_MODEL_DIR set, the whole session must
//  reproduce both windows (denoised tokens, decoder input, decoded root
//  and rotations) and fill a LiveMotionSession with 80 frames.
//  docs/REALTIME_MOTION_PLAN.md, Phase 3.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import Metal
import Testing
import simd

@testable import NeuraLink

private final class MotionFixtureMarker {}

private struct MotionWindowFixture: Decodable {
    let historyTokens: Int
    let preparedHistory: [Float]?
    let firstHeading: Float
    let globalTranslationIn: [Float]
    let noise: [Float]
    let denoised: [Float]
    let decoderInput: [Float]
    let globalTranslation: [Float]
    let localRotationsFrame0: [Float]
    let localRotationsLast: [Float]
    let rootPositions: [Float]
    let newHybridTokens: [Float]
    enum CodingKeys: String, CodingKey {
        case noise, denoised
        case historyTokens = "history_tokens"
        case preparedHistory = "prepared_history"
        case firstHeading = "first_heading"
        case globalTranslationIn = "global_translation_in"
        case decoderInput = "decoder_input"
        case globalTranslation = "global_translation"
        case localRotationsFrame0 = "local_rotations_frame0"
        case localRotationsLast = "local_rotations_last"
        case rootPositions = "root_positions"
        case newHybridTokens = "new_hybrid_tokens"
    }
}

private struct MotionManifestFixture: Decodable {
    let dimensions: ARDYWindowLayout
    let recenter: ARDYRecenter
    let latentQuantization: ARDYLatentQuantization
    enum CodingKeys: String, CodingKey {
        case dimensions, recenter
        case latentQuantization = "latent_quantization"
    }
}

private struct MotionTokens: Decodable {
    let ids: [Int64]
}

private struct MotionFixture: Decodable {
    let caption: String
    let seed: UInt32
    let tokens: MotionTokens
    let textConditions: [Float]
    let windows: [MotionWindowFixture]
    let tokenExamples: [String: MotionTokens]
    enum CodingKeys: String, CodingKey {
        case caption, seed, tokens, windows
        case textConditions = "text_conditions"
        case tokenExamples = "token_examples"
    }
}

@Suite("Motion generation session", .serialized)
struct MotionGenerationSessionTests {

    @Test("The noise source reproduces the fixture's first window")
    func noiseMatches() throws {
        let fixture = try Self.loadFixture()
        var random = ARDYPortableRandom(seed: fixture.seed)
        var noise = [Float](repeating: 0, count: 20 * 148)
        random.fillNormal(&noise, from: 0, to: 10 * 148)
        let error = zip(noise, fixture.windows[0].noise).map { abs($0 - $1) }.max() ?? 1
        #expect(error == 0, "first-window noise differs by \(error)")
        // The second window's noise follows the same stream: 10 history
        // tokens, then the next 10 × 148 Gaussians.
        var second = [Float](repeating: 0, count: 20 * 148)
        random.fillNormal(&second, from: 10 * 148, to: 20 * 148)
        let secondError = zip(second[(10 * 148)...], fixture.windows[1].noise[(10 * 148)...]).map { abs($0 - $1) }.max() ?? 1
        #expect(secondError == 0, "second-window noise differs by \(secondError)")
    }

    @Test("WordPiece ids match the Python tokenizer")
    func tokenizerMatches() throws {
        let fixture = try Self.loadFixture()
        let tokenizer = try ARDYPromptTokenizer(directory: Self.fixtureURL("ardy_tokenizer", nil))
        for (caption, expected) in fixture.tokenExamples {
            let encoded = tokenizer.encode(caption)
            #expect(encoded.ids == expected.ids, "\(caption): \(encoded.ids) vs \(expected.ids)")
            #expect(encoded.attentionMask.count == expected.ids.count)
        }
    }

    @Test("Recentering and requantization reproduce the decoder inputs")
    func recenterMatches() throws {
        let fixture = try Self.loadFixture()
        let math = try Self.windowMath()
        for (index, window) in fixture.windows.enumerated() {
            let valid = window.historyTokens + 10
            var input = [Float](repeating: 0, count: 20 * 148)
            input.replaceSubrange(0..<(valid * 148), with: window.denoised[0..<(valid * 148)])
            let translationIn = SIMD3<Float>(window.globalTranslationIn[0], window.globalTranslationIn[1], window.globalTranslationIn[2])
            let result = math.recenterAndRequantize(&input, validTokens: valid, globalTranslation: translationIn, nextHistoryStartToken: max(0, valid - 10))
            let error = zip(input, window.decoderInput).map { abs($0 - $1) }.max() ?? 1
            #expect(error < 1e-6, "window \(index + 1): decoder input differs by \(error)")
            let translationError = abs(result.globalTranslation.x - window.globalTranslation[0]) + abs(result.globalTranslation.z - window.globalTranslation[2])
            #expect(translationError < 1e-5, "window \(index + 1): translation differs by \(translationError)")
        }
        // The second window's history came from the first window's new
        // tokens, recentered the way prepareHistory does.
        let prepared = math.prepareHistory(
            globalHybrid: fixture.windows[0].newHybridTokens, frameCount: 40, requestedFrames: 40, initialTranslation: .zero, initialHeading: 0)
        #expect(prepared.historyTokens == 10)
        let expectedHistory = try #require(fixture.windows[1].preparedHistory)
        let historyError = zip(prepared.history ?? [], expectedHistory).map { abs($0 - $1) }.max() ?? 1
        #expect(historyError < 1e-6, "prepared history differs by \(historyError)")
        #expect(abs(prepared.firstHeadingAngle - fixture.windows[1].firstHeading) < 1e-5)
    }

    @Test("Ties-to-even rounding")
    func rounding() {
        #expect(ARDYWindowMath.roundTiesToEven(0.5) == 0)
        #expect(ARDYWindowMath.roundTiesToEven(1.5) == 2)
        #expect(ARDYWindowMath.roundTiesToEven(-0.5) == 0)
        #expect(ARDYWindowMath.roundTiesToEven(-1.5) == -2)
        #expect(ARDYWindowMath.roundTiesToEven(2.4) == 2)
        #expect(ARDYWindowMath.roundTiesToEven(2.6) == 3)
    }

    @Test("The whole session reproduces two windows when NL_MOTION_MODEL_DIR is set")
    func sessionMatches() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_MOTION_MODEL_DIR"], !path.isEmpty,
              let device = MTLCreateSystemDefaultDevice() else { return }
        let fixture = try Self.loadFixture()
        let modelDir = URL(fileURLWithPath: path, isDirectory: true)
        let runtime = try ARDYMotionRuntime(modelDirectory: modelDir, provider: .cpu)
        let tokenizer = try ARDYPromptTokenizer(directory: modelDir.appendingPathComponent("tokenizer", isDirectory: true))
        let session = MotionGenerationSession(runtime: runtime, tokenizer: tokenizer, seed: fixture.seed)
        try await session.start(caption: fixture.caption)

        let modelURL = try #require(Bundle.main.url(forResource: "Sonya", withExtension: "vrm"))
        let model = try await VRMModel.load(from: modelURL, device: device)
        let live = LiveMotionSession(model: model, framesPerSecond: await session.framesPerSecond)
        for (index, expected) in fixture.windows.enumerated() {
            let window = try await session.nextWindow(into: live)
            #expect(window.frames == 40)
            #expect(window.startFrame == index * 40)
            let rootError = zip(window.rootPositions, expected.rootPositions).map { abs($0 - $1) }.max() ?? 1
            #expect(rootError < 1e-3, "window \(index + 1): root positions differ by \(rootError)")
            let stride = 27 * 9
            let firstError = zip(window.localRotations.prefix(stride), expected.localRotationsFrame0).map { abs($0 - $1) }.max() ?? 1
            let lastError = zip(window.localRotations.suffix(stride), expected.localRotationsLast).map { abs($0 - $1) }.max() ?? 1
            #expect(firstError < 1e-3 && lastError < 1e-3, "window \(index + 1): rotations differ by \(firstError) / \(lastError)")
        }
        #expect(live.buffer.frameCount == 80)
        #expect(abs(live.buffer.duration - 4) < 1e-5)
        #expect(live.buffer.sample(at: 3.95) != nil)
    }

    // MARK: - Fixtures

    private static func windowMath() throws -> ARDYWindowMath {
        let manifest = try JSONDecoder().decode(MotionManifestFixture.self, from: Data(contentsOf: fixtureURL("ardy_mini_manifest", "json")))
        return ARDYWindowMath(layout: manifest.dimensions, recenter: manifest.recenter, quantization: manifest.latentQuantization)
    }

    private static func fixtureURL(_ name: String, _ ext: String?) throws -> URL {
        let bundle = Bundle(for: MotionFixtureMarker.self)
        let bundled = ext.flatMap { bundle.url(forResource: name, withExtension: $0) } ?? bundle.resourceURL?.appendingPathComponent(name)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)\(ext.map { ".\($0)" } ?? "")")
        if FileManager.default.fileExists(atPath: source.path) { return source }
        return try #require(bundled)
    }

    private static func loadFixture() throws -> MotionFixture {
        try JSONDecoder().decode(MotionFixture.self, from: Data(contentsOf: fixtureURL("ardy_mini_wave_windows", "json")))
    }
}
