//
//  ARDYWindowMath.swift
//  NeuraLink
//
//  The autoregressive window bookkeeping around the bridge, ported from the
//  browser runtime (web/src/runtime/{engine,windows}.ts in intsuc/ardy-mini)
//  and the Phase 0 driver: a 20-token window of 148-float hybrid tokens
//  (four frames each; five root features a frame, then a 128-float FSQ
//  latent), history tokens first, Gaussian noise in the generation slots.
//  After denoising, root x/z are recentered on the last valid frame and the
//  latents snapped back to the quantizer's grid before decoding; the decoded
//  world root features and the requantized latents become the history the
//  next window continues from. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import simd

/// The `dimensions` block of model.json.
struct ARDYWindowLayout: Decodable, Sendable {
    let maxTokens: Int
    let hybridDim: Int
    let numFramesPerToken: Int
    let historyTokens: Int
    let generationTokens: Int
    let generationFrames: Int
    let maxFrames: Int
    let rootFeaturesPerFrame: Int
    let nframeRootDim: Int
    let latentDim: Int
    let motionDim: Int
    let fps: Int

    enum CodingKeys: String, CodingKey {
        case fps
        case maxTokens = "max_tokens"
        case hybridDim = "hybrid_dim"
        case numFramesPerToken = "num_frames_per_token"
        case historyTokens = "history_tokens"
        case generationTokens = "generation_tokens"
        case generationFrames = "generation_frames"
        case maxFrames = "max_frames"
        case rootFeaturesPerFrame = "root_features_per_frame"
        case nframeRootDim = "nframe_root_dim"
        case latentDim = "latent_dim"
        case motionDim = "motion_dim"
    }

    var windowFloats: Int { maxTokens * hybridDim }
}

/// The `recenter` block: how root features are normalized.
struct ARDYRecenter: Decodable, Sendable {
    let positionIndices: [Int]
    let headingIndices: [Int]
    let rootMean: [Float]
    let rootStd: [Float]

    enum CodingKeys: String, CodingKey {
        case positionIndices = "position_indices"
        case headingIndices = "heading_indices"
        case rootMean = "root_mean"
        case rootStd = "root_std"
    }
}

/// The `latent_quantization` block: the FSQ grid per latent feature.
struct ARDYLatentQuantization: Decodable, Sendable {
    let levels: [Int]
    let mean: [Float]
    let std: [Float]
}

/// A window ready for the bridge, plus where its generation slots are.
struct ARDYWindow: Sendable {
    var hybrid: [Float]
    let historyTokens: Int
    let generationTokens: Int
    var validTokens: Int { historyTokens + generationTokens }
    var historyFrames: Int
}

/// What continuing from the kept history needs: the recentered history
/// tokens (nil for a fresh start) and the world transform the decoder adds back.
struct ARDYPreparedHistory: Sendable {
    let history: [Float]?
    let historyTokens: Int
    let globalTranslation: SIMD3<Float>
    let firstHeadingAngle: Float
}

struct ARDYWindowMath: Sendable {
    let layout: ARDYWindowLayout
    let recenter: ARDYRecenter
    let quantization: ARDYLatentQuantization

    // MARK: Root features

    func rootOffset(frame: Int, feature: Int) -> Int {
        (frame / layout.numFramesPerToken) * layout.hybridDim + (frame % layout.numFramesPerToken) * layout.rootFeaturesPerFrame + feature
    }

    func rawRoot(_ buffer: [Float], frame: Int, feature: Int) -> Float {
        buffer[rootOffset(frame: frame, feature: feature)] * recenter.rootStd[feature] + recenter.rootMean[feature]
    }

    func setRoot(_ buffer: inout [Float], frame: Int, feature: Int, raw: Float) {
        buffer[rootOffset(frame: frame, feature: feature)] = (raw - recenter.rootMean[feature]) / recenter.rootStd[feature]
    }

    // MARK: Continuation

    /// The browser's `prepareHistory`: up to `requestedFrames` of the most
    /// recent history, recentered on its last frame in x/z (and on the
    /// initial y), with the world translation and the heading of its first
    /// frame for the decoder and the denoiser.
    func prepareHistory(
        globalHybrid: [Float], frameCount: Int, requestedFrames: Int, initialTranslation: SIMD3<Float>, initialHeading: Float
    ) -> ARDYPreparedHistory {
        let perToken = layout.numFramesPerToken
        let available = min(frameCount / perToken, globalHybrid.count / layout.hybridDim)
        let requested = min(layout.historyTokens, requestedFrames / perToken, available)
        let (px, py, pz) = (recenter.positionIndices[0], recenter.positionIndices[1], recenter.positionIndices[2])
        let (hc, hs) = (recenter.headingIndices[0], recenter.headingIndices[1])
        if requested == 0 {
            guard available > 0 else {
                return ARDYPreparedHistory(history: nil, historyTokens: 0, globalTranslation: initialTranslation, firstHeadingAngle: initialHeading)
            }
            let last = available * perToken - 1
            let translation = SIMD3<Float>(rawRoot(globalHybrid, frame: last, feature: px), initialTranslation.y, rawRoot(globalHybrid, frame: last, feature: pz))
            let heading = atan2(rawRoot(globalHybrid, frame: last, feature: hs), rawRoot(globalHybrid, frame: last, feature: hc))
            return ARDYPreparedHistory(history: nil, historyTokens: 0, globalTranslation: translation, firstHeadingAngle: heading)
        }
        let first = available - requested
        var history = Array(globalHybrid[(first * layout.hybridDim)..<(available * layout.hybridDim)])
        let historyFrames = requested * perToken
        let centerX = rawRoot(history, frame: historyFrames - 1, feature: px)
        let centerZ = rawRoot(history, frame: historyFrames - 1, feature: pz)
        let heading = atan2(rawRoot(history, frame: 0, feature: hs), rawRoot(history, frame: 0, feature: hc))
        for frame in 0..<historyFrames {
            setRoot(&history, frame: frame, feature: px, raw: rawRoot(history, frame: frame, feature: px) - centerX)
            setRoot(&history, frame: frame, feature: py, raw: rawRoot(history, frame: frame, feature: py) - initialTranslation.y)
            setRoot(&history, frame: frame, feature: pz, raw: rawRoot(history, frame: frame, feature: pz) - centerZ)
        }
        return ARDYPreparedHistory(
            history: history, historyTokens: requested, globalTranslation: SIMD3<Float>(centerX, initialTranslation.y, centerZ), firstHeadingAngle: heading)
    }

    /// The browser's `createArWindow`: history first, noise in the generation slots.
    func makeWindow(history: [Float]?, random: inout ARDYPortableRandom) -> ARDYWindow {
        let historyTokens = (history?.count ?? 0) / layout.hybridDim
        var hybrid = [Float](repeating: 0, count: layout.windowFloats)
        if let history { hybrid.replaceSubrange(0..<history.count, with: history) }
        let noiseStart = historyTokens * layout.hybridDim
        random.fillNormal(&hybrid, from: noiseStart, to: noiseStart + layout.generationTokens * layout.hybridDim)
        return ARDYWindow(hybrid: hybrid, historyTokens: historyTokens, generationTokens: layout.generationTokens, historyFrames: historyTokens * layout.numFramesPerToken)
    }

    // MARK: Recentering and requantization

    /// The browser's `recenterAndRequantize`, in place: root x/z centred on
    /// the last valid frame, latents snapped to the FSQ grid with
    /// ties-to-even rounding. Returns the decoder's world translation and
    /// the heading at `nextHistoryStartToken`.
    func recenterAndRequantize(_ hybrid: inout [Float], validTokens: Int, globalTranslation: SIMD3<Float>, nextHistoryStartToken: Int)
        -> (globalTranslation: SIMD3<Float>, firstHeadingAngle: Float) {
        let validFrames = validTokens * layout.numFramesPerToken
        let (px, pz) = (recenter.positionIndices[0], recenter.positionIndices[2])
        let (hc, hs) = (recenter.headingIndices[0], recenter.headingIndices[1])
        let centerX = rawRoot(hybrid, frame: validFrames - 1, feature: px)
        let centerZ = rawRoot(hybrid, frame: validFrames - 1, feature: pz)
        for frame in 0..<validFrames {
            setRoot(&hybrid, frame: frame, feature: px, raw: rawRoot(hybrid, frame: frame, feature: px) - centerX)
            setRoot(&hybrid, frame: frame, feature: pz, raw: rawRoot(hybrid, frame: frame, feature: pz) - centerZ)
        }
        for token in 0..<validTokens {
            let base = token * layout.hybridDim + layout.nframeRootDim
            for feature in 0..<layout.latentDim {
                let index = base + feature
                let raw = Double(hybrid[index]) * Double(quantization.std[feature]) + Double(quantization.mean[feature])
                let halfWidth = Double(quantization.levels[feature] / 2)
                let discrete = Self.roundTiesToEven(min(1, max(-1, raw)) * halfWidth) / halfWidth
                hybrid[index] = Float((discrete - Double(quantization.mean[feature])) / Double(quantization.std[feature]))
            }
        }
        let firstFrame = nextHistoryStartToken * layout.numFramesPerToken
        let heading = atan2(rawRoot(hybrid, frame: firstFrame, feature: hs), rawRoot(hybrid, frame: firstFrame, feature: hc))
        return (globalTranslation + SIMD3<Float>(centerX, 0, centerZ), heading)
    }

    /// The browser's `buildGlobalHybridTokens`: the generated tokens as the
    /// next history, with the decoded world root features in place of the
    /// recentered ones and the requantized latents kept.
    func historyTokens(decodedMotion: [Float], decoderHybrid: [Float], generatedFrameOffset: Int, generationTokenOffset: Int, tokenCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: tokenCount * layout.hybridDim)
        for token in 0..<tokenCount {
            let destination = token * layout.hybridDim
            let source = (generationTokenOffset + token) * layout.hybridDim
            for frameInToken in 0..<layout.numFramesPerToken {
                let sourceFrame = generatedFrameOffset + token * layout.numFramesPerToken + frameInToken
                let motionBase = sourceFrame * layout.motionDim
                let rootBase = destination + frameInToken * layout.rootFeaturesPerFrame
                for feature in 0..<layout.rootFeaturesPerFrame {
                    result[rootBase + feature] = decodedMotion[motionBase + feature]
                }
            }
            for offset in layout.nframeRootDim..<layout.hybridDim {
                result[destination + offset] = decoderHybrid[source + offset]
            }
        }
        return result
    }

    /// PyTorch's rounding, not Foundation's `rounded()` (which rounds half away from zero).
    static func roundTiesToEven(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let floor = value.rounded(.down)
        let fraction = value - floor
        if fraction < 0.5 { return floor }
        if fraction > 0.5 { return floor + 1 }
        return floor.truncatingRemainder(dividingBy: 2) == 0 ? floor : floor + 1
    }
}
