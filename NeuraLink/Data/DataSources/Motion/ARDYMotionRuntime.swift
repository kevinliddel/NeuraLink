//
//  ARDYMotionRuntime.swift
//  NeuraLink
//
//  Swift face of motion_bridge: the three ARDY-mini ONNX sessions plus the
//  diffusion schedule read from the model directory's model.json. One window
//  call runs the whole DDIM recurrence in the bridge. Window bookkeeping
//  (history, recentering, requantization) lives one layer up.
//
//  Created by Dedicatus on 29/10/20226.
//

import Foundation

/// Which execution provider the bridge should try first; it falls back
/// through XNNPACK to the CPU provider when one is not compiled in.
enum ARDYMotionProvider: Int32, CaseIterable, Sendable {
    case cpu = 0
    case xnnpack = 1
    case coreML = 2

    var label: String {
        switch self {
        case .cpu: return "cpu"
        case .xnnpack: return "xnnpack"
        case .coreML: return "coreml"
        }
    }
}

enum ARDYMotionRuntimeError: Error {
    case manifestUnreadable(String)
    case sessionsFailed(String)
    case bridgeFailed(String, Double)
}

/// The DDIM schedule from model.json's `diffusion` block, in inference order.
struct ARDYDiffusionSchedule: Sendable {
    let timesteps: [Int32]
    let alphasCumprod: [Float]
    let alphasCumprodPrev: [Float]

    /// The full published schedule, or every `steps`-th timestep of it with
    /// the previous-alpha chain rebuilt so the last step still lands on
    /// alpha_prev = 1 (the recurrence the Phase 0 driver used for 4–8 steps).
    func stepsSchedule(_ steps: Int) -> (timesteps: [Int32], alphas: [Float], alphasPrev: [Float]) {
        let count = timesteps.count
        guard steps > 0, steps < count else {
            return (
                timesteps, timesteps.map { alphasCumprod[Int($0)] },
                timesteps.map { alphasCumprodPrev[Int($0)] }
            )
        }
        let picked = (0..<steps).map { index -> Int32 in
            let position = Float(index) * Float(count - 1) / Float(steps - 1)
            return timesteps[Int(position.rounded())]
        }
        let alphas = picked.map { alphasCumprod[Int($0)] }
        var previous: [Float] = []
        for index in 0..<steps {
            previous.append(
                index == steps - 1
                    ? alphasCumprodPrev[Int(picked[index])] : alphasCumprod[Int(picked[index + 1])])
        }
        return (picked, alphas, previous)
    }
}

/// One decoded window of 80 frames on the 27-joint ARDY skeleton.
struct ARDYDecodedWindow: Sendable {
    static let frames = Int(MOTION_BRIDGE_FRAMES)
    static let joints = Int(MOTION_BRIDGE_JOINTS)
    static let motionDimension = Int(MOTION_BRIDGE_MOTION_DIM)
    /// Row-major 3x3 per joint per frame.
    let localRotations: [Float]
    let globalRotations: [Float]
    let rootPositions: [Float]
    let footContacts: [UInt8]
    /// FRAMES × 330 normalized motion features; the first five per frame are
    /// the world root features the next window's history is built from.
    let normalizedMotion: [Float]
    let milliseconds: Double
}

/// Where the model lives: model.json, the three graphs and the tokenizer's
/// two files, wherever each sits (the download cache names them
/// distinctively; a folder uses the standard names).
struct ARDYModelFiles: Sendable, Equatable {
    let manifest: URL
    let textEncoder: URL
    let denoiser: URL
    let decoder: URL
    let tokenizer: URL
    let tokenizerConfig: URL

    /// The standard names inside `directory`, tokenizer files under `tokenizer/`.
    init(directory: URL) {
        manifest = directory.appendingPathComponent("model.json")
        textEncoder = directory.appendingPathComponent("text_encoder.onnx")
        denoiser = directory.appendingPathComponent("denoiser.onnx")
        decoder = directory.appendingPathComponent("decoder.onnx")
        tokenizer = directory.appendingPathComponent("tokenizer/tokenizer.json")
        tokenizerConfig = directory.appendingPathComponent("tokenizer/tokenizer_config.json")
    }

    init(manifest: URL, textEncoder: URL, denoiser: URL, decoder: URL, tokenizer: URL, tokenizerConfig: URL) {
        self.manifest = manifest
        self.textEncoder = textEncoder
        self.denoiser = denoiser
        self.decoder = decoder
        self.tokenizer = tokenizer
        self.tokenizerConfig = tokenizerConfig
    }

    var all: [URL] { [manifest, textEncoder, denoiser, decoder, tokenizer, tokenizerConfig] }

    /// Every file present on disk.
    var isComplete: Bool { all.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
}

final class ARDYMotionRuntime: @unchecked Sendable {
    static let tokens = Int(MOTION_BRIDGE_TOKENS)
    static let hybridDimension = Int(MOTION_BRIDGE_HYBRID_DIM)
    static let textDimension = Int(MOTION_BRIDGE_TEXT_DIM)
    static let windowFloats = tokens * hybridDimension

    let files: ARDYModelFiles
    let provider: ARDYMotionProvider
    let schedule: ARDYDiffusionSchedule
    let defaultCFGWeight: Float
    /// The window bookkeeping constants from the same model.json.
    let windowMath: ARDYWindowMath
    private var handle: OpaquePointer?

    static var runtimeVersion: String { String(cString: motion_bridge_runtime_version()) }
    static var lastError: String { String(cString: motion_bridge_last_error()) }
    /// "generic+cache", "generic", "legacy" or "" — how CoreML was registered.
    var coreMLRegistration: String { handle.map { String(cString: motion_bridge_coreml_registration($0)) } ?? "" }

    /// Compiled CoreML models are kept here between runs when the runtime can.
    static var compiledModelCache: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("ardy-coreml-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The standard file names inside one folder (the bench, tests, a hand-copied model).
    convenience init(modelDirectory: URL, provider requested: ARDYMotionProvider = .coreML, threads: Int32 = 0) throws {
        try self.init(files: ARDYModelFiles(directory: modelDirectory), provider: requested, threads: threads)
    }

    init(files: ARDYModelFiles, provider requested: ARDYMotionProvider = .coreML, threads: Int32 = 0) throws {
        self.files = files
        let manifest = try Self.readManifest(at: files.manifest)
        schedule = manifest.schedule
        defaultCFGWeight = manifest.cfgWeight
        windowMath = ARDYWindowMath(layout: manifest.dimensions, recenter: manifest.recenter, quantization: manifest.latentQuantization)
        var used: Int32 = ARDYMotionProvider.cpu.rawValue
        let cache = Self.compiledModelCache.path
        guard let created = motion_bridge_create(
            files.textEncoder.path, files.denoiser.path, files.decoder.path, requested.rawValue, threads, cache, &used)
        else {
            let reason = Self.lastError
            nlLog("[ARDYMotion] Sessions failed for \(requested.label): \(reason)", level: .warning)
            throw ARDYMotionRuntimeError.sessionsFailed(reason)
        }
        handle = created
        provider = ARDYMotionProvider(rawValue: used) ?? .cpu
        nlLog(
            "[ARDYMotion] Sessions ready: requested \(requested.label), using \(provider.label) (\(coreMLRegistration)), ORT \(Self.runtimeVersion)",
            level: .info)
    }

    deinit {
        if let handle { motion_bridge_free(handle) }
    }

    /// 2048 root/body conditions for one tokenized prompt.
    func encodeText(ids: [Int64], attentionMask: [Int64], tokenTypeIds: [Int64]) throws -> (
        conditions: [Float], milliseconds: Double
    ) {
        guard let handle, !ids.isEmpty, ids.count == attentionMask.count,
            ids.count == tokenTypeIds.count
        else {
            throw ARDYMotionRuntimeError.bridgeFailed("encode", -1)
        }
        var out = [Float](repeating: 0, count: Self.textDimension)
        let elapsed = motion_bridge_encode_text(
            handle, ids, attentionMask, tokenTypeIds, Int32(ids.count), &out)
        guard elapsed >= 0 else { throw ARDYMotionRuntimeError.bridgeFailed("encode", elapsed) }
        return (out, elapsed)
    }

    /// Denoises the generation slots of `window` in place. Returns per-step
    /// wall times in ms.
    func denoise(
        window: inout [Float], historyTokens: Int, generationTokens: Int = 10, conditions: [Float],
        cfgWeight: Float? = nil, firstHeadingAngle: Float = 0, steps: Int = 0
    ) throws -> [Double] {
        guard let handle, window.count == Self.windowFloats, conditions.count == Self.textDimension
        else {
            throw ARDYMotionRuntimeError.bridgeFailed("denoise", -1)
        }
        let plan = schedule.stepsSchedule(steps)
        var stepMilliseconds = [Double](repeating: 0, count: plan.timesteps.count)
        let elapsed = motion_bridge_denoise(
            handle, &window, Int32(historyTokens), Int32(generationTokens), conditions,
            cfgWeight ?? defaultCFGWeight,
            firstHeadingAngle, plan.timesteps, plan.alphas, plan.alphasPrev,
            Int32(plan.timesteps.count), &stepMilliseconds)
        guard elapsed >= 0 else { throw ARDYMotionRuntimeError.bridgeFailed("denoise", elapsed) }
        return stepMilliseconds
    }

    func decode(hybrid: [Float], validTokens: Int, globalTranslation: SIMD3<Float>) throws -> ARDYDecodedWindow {
        guard let handle, hybrid.count == Self.windowFloats else {
            throw ARDYMotionRuntimeError.bridgeFailed("decode", -1)
        }
        let rotations = ARDYDecodedWindow.frames * ARDYDecodedWindow.joints * 9
        var local = [Float](repeating: 0, count: rotations)
        var global = [Float](repeating: 0, count: rotations)
        var root = [Float](repeating: 0, count: ARDYDecodedWindow.frames * 3)
        var contacts = [UInt8](repeating: 0, count: ARDYDecodedWindow.frames * 4)
        var motion = [Float](repeating: 0, count: ARDYDecodedWindow.frames * ARDYDecodedWindow.motionDimension)
        let translation = [globalTranslation.x, globalTranslation.y, globalTranslation.z]
        let elapsed = motion_bridge_decode(
            handle, hybrid, Int32(validTokens), translation, &local, &global, &root, &contacts, &motion)
        guard elapsed >= 0 else { throw ARDYMotionRuntimeError.bridgeFailed("decode", elapsed) }
        return ARDYDecodedWindow(
            localRotations: local, globalRotations: global, rootPositions: root,
            footContacts: contacts, normalizedMotion: motion, milliseconds: elapsed)
    }

    // MARK: - Manifest

    private static func readManifest(at url: URL) throws -> ARDYModelManifest {
        do {
            return try JSONDecoder().decode(ARDYModelManifest.self, from: Data(contentsOf: url))
        } catch {
            throw ARDYMotionRuntimeError.manifestUnreadable("\(url.path): \(error)")
        }
    }
}

// MARK: - model.json (the parts the runtime needs)

private struct ARDYManifestDiffusion: Decodable {
    let timesteps: [Int32]
    let alphasCumprod: [Float]
    let alphasCumprodPrev: [Float]
    enum CodingKeys: String, CodingKey {
        case timesteps
        case alphasCumprod = "alphas_cumprod"
        case alphasCumprodPrev = "alphas_cumprod_prev"
    }
}

private struct ARDYManifestGeneration: Decodable {
    let defaultCfgWeight: Float
    enum CodingKeys: String, CodingKey { case defaultCfgWeight = "default_cfg_weight" }
}

private struct ARDYModelManifest: Decodable {
    let diffusion: ARDYManifestDiffusion
    let generation: ARDYManifestGeneration
    let dimensions: ARDYWindowLayout
    let recenter: ARDYRecenter
    let latentQuantization: ARDYLatentQuantization

    enum CodingKeys: String, CodingKey {
        case diffusion, generation, dimensions, recenter
        case latentQuantization = "latent_quantization"
    }

    var schedule: ARDYDiffusionSchedule {
        ARDYDiffusionSchedule(
            timesteps: diffusion.timesteps, alphasCumprod: diffusion.alphasCumprod,
            alphasCumprodPrev: diffusion.alphasCumprodPrev)
    }
    var cfgWeight: Float { generation.defaultCfgWeight }
}
