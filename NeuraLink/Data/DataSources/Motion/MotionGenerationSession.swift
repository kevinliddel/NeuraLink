//
//  MotionGenerationSession.swift
//  NeuraLink
//
//  One caption's motion, a 2 s window at a time: tokenizer → text encoder →
//  denoised window → recenter and requantize → decoder, with the decoded
//  world root and the requantized latents kept as the history the next
//  window continues from. A new caption replans at the next window as a
//  fresh inference that keeps position and heading (text-to-vrma's finding:
//  carrying the old action's history smothers the new one); the first
//  frames of that window are blended from the last pose so the body does
//  not snap. Frames go to a LiveMotionSession, which retargets them.
//  See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import os
import simd

/// One decoded window's frames, in the decoder's layout.
struct ARDYGeneratedWindow: Sendable {
    let startFrame: Int
    let frames: Int
    let globalRotations: [Float]
    let localRotations: [Float]
    let rootPositions: [Float]
    let footContacts: [UInt8]
    let timings: (denoise: Double, decode: Double)
}

/// How the body carries over into a window.
enum ARDYHistoryPolicy: Sendable {
    /// Up to 40 frames: smooth, finite actions.
    case full
    /// Four frames: repeated actions keep going instead of dying out.
    case short
    /// No frames: a new action starts fresh, position and heading kept.
    case fresh

    var frames: Int {
        switch self {
        case .full: return 40
        case .short: return 4
        case .fresh: return 0
        }
    }
}

actor MotionGenerationSession {
    /// Frames blended from the last pose into a replanned window.
    static let replanBlendFrames = 8

    private let runtime: ARDYMotionRuntime
    private let tokenizer: ARDYPromptTokenizer
    private let math: ARDYWindowMath
    private var random: ARDYPortableRandom
    private var conditions: [Float] = []
    private(set) var caption = ""
    private var globalHybrid: [Float] = []
    private(set) var frameCount = 0
    private var initialTranslation = SIMD3<Float>(repeating: 0)
    private var initialHeading: Float = 0
    private var nextWindowPolicy: ARDYHistoryPolicy = .full
    private var blendNextWindow = false
    var historyPolicy: ARDYHistoryPolicy = .full
    var steps = 0
    var cfgWeight: Float?

    init(runtime: ARDYMotionRuntime, tokenizer: ARDYPromptTokenizer, seed: UInt32) {
        self.runtime = runtime
        self.tokenizer = tokenizer
        math = runtime.windowMath
        random = ARDYPortableRandom(seed: seed)
    }

    var framesPerSecond: Float { Float(math.layout.fps) }

    /// Starts over on `caption`: history, playhead and noise reset.
    func start(caption: String, seed: UInt32? = nil) throws {
        if let seed { random = ARDYPortableRandom(seed: seed) }
        globalHybrid = []
        frameCount = 0
        initialTranslation = .zero
        initialHeading = 0
        blendNextWindow = false
        nextWindowPolicy = historyPolicy
        try encode(caption)
    }

    /// Changes the caption for every window from the next one on: a fresh
    /// inference from the current position and heading, blended in.
    func replan(caption: String) throws {
        try encode(caption)
        nextWindowPolicy = .fresh
        blendNextWindow = frameCount > 0
    }

    private func encode(_ text: String) throws {
        let signpost = NLSignposts.motion.beginInterval("encodeText")
        defer { NLSignposts.motion.endInterval("encodeText", signpost) }
        let tokens = tokenizer.encode(text)
        conditions = try runtime.encodeText(ids: tokens.ids, attentionMask: tokens.attentionMask, tokenTypeIds: tokens.tokenTypeIds).conditions
        caption = text
    }

    /// Generates the next window (40 frames) and returns its decoded frames.
    func nextWindow() throws -> ARDYGeneratedWindow {
        guard !conditions.isEmpty else { throw ARDYMotionRuntimeError.bridgeFailed("start first", -1) }
        let signpost = NLSignposts.motion.beginInterval("window")
        defer { NLSignposts.motion.endInterval("window", signpost) }
        let layout = math.layout
        let prepared = math.prepareHistory(
            globalHybrid: globalHybrid, frameCount: frameCount, requestedFrames: nextWindowPolicy.frames,
            initialTranslation: initialTranslation, initialHeading: initialHeading)
        var window = math.makeWindow(history: prepared.history, random: &random)
        let stepMs = try runtime.denoise(
            window: &window.hybrid, historyTokens: window.historyTokens, generationTokens: window.generationTokens, conditions: conditions,
            cfgWeight: cfgWeight, firstHeadingAngle: prepared.firstHeadingAngle, steps: steps)

        var decoderInput = [Float](repeating: 0, count: layout.windowFloats)
        let validFloats = window.validTokens * layout.hybridDim
        decoderInput.replaceSubrange(0..<validFloats, with: window.hybrid[0..<validFloats])
        let recentered = math.recenterAndRequantize(
            &decoderInput, validTokens: window.validTokens, globalTranslation: prepared.globalTranslation,
            nextHistoryStartToken: max(0, window.validTokens - layout.historyTokens))
        let decoded = try runtime.decode(hybrid: decoderInput, validTokens: window.validTokens, globalTranslation: recentered.globalTranslation)

        let generated = layout.generationFrames
        let offset = window.historyFrames
        globalHybrid += math.historyTokens(
            decodedMotion: decoded.normalizedMotion, decoderHybrid: decoderInput, generatedFrameOffset: offset,
            generationTokenOffset: window.historyTokens, tokenCount: layout.generationTokens)
        let startFrame = frameCount
        frameCount += generated
        nextWindowPolicy = historyPolicy
        let rotationStride = ARDYDecodedWindow.joints * 9
        let result = ARDYGeneratedWindow(
            startFrame: startFrame, frames: generated,
            globalRotations: Array(decoded.globalRotations[(offset * rotationStride)..<((offset + generated) * rotationStride)]),
            localRotations: Array(decoded.localRotations[(offset * rotationStride)..<((offset + generated) * rotationStride)]),
            rootPositions: Array(decoded.rootPositions[(offset * 3)..<((offset + generated) * 3)]),
            footContacts: Array(decoded.footContacts[(offset * 4)..<((offset + generated) * 4)]),
            timings: (stepMs.reduce(0, +), decoded.milliseconds))
        nlLog("[Bench] motion window \(startFrame / generated): denoise \(Int(result.timings.denoise)) ms (\(stepMs.count) steps), decode \(Int(result.timings.decode)) ms, history \(window.historyTokens) tok", level: .info)
        return result
    }

    /// Generates the next window straight into `live`, blending the first
    /// frames after a replan. Returns the window.
    @discardableResult
    func nextWindow(into live: LiveMotionSession) throws -> ARDYGeneratedWindow {
        let blend = blendNextWindow
        blendNextWindow = false
        let window = try nextWindow()
        live.append(frames: window.frames, globalRotations: window.globalRotations, rootPositions: window.rootPositions,
                    blendingFirst: blend ? Self.replanBlendFrames : 0)
        return window
    }
}
