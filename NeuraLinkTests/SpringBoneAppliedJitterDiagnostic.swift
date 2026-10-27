//
//  SpringBoneAppliedJitterDiagnostic.swift
//  NeuraLinkTests
//
//  Developer tool: hair jitter as the app shows it — the frame loop's own
//  path (animation pose, spring solve, posed joints) paced at 60 Hz, with
//  the posed joints' world positions measured. Once with the GPU otherwise
//  idle and once while a second queue keeps it busy (the local LLM
//  generating): the GPU solver this replaced shook under that load. Set
//  NL_SPRING_APPLIED_DIR to run; NL_SPRING_DIAG_MODELS adds colon-separated
//  .vrm paths.
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import Metal
import Testing
import simd
@testable import NeuraLink

@Suite("Spring bone applied jitter diagnostic", .serialized)
struct SpringBoneAppliedJitterDiagnostic {

    @Test("Measure applied hair jitter when NL_SPRING_APPLIED_DIR is set")
    @MainActor
    func measure() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NL_SPRING_APPLIED_DIR"], !path.isEmpty,
              let device = MTLCreateSystemDefaultDevice() else { return }
        let outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var models: [(String, URL)] = []
        for name in ["Oz", "Ekaterina", "Sonya"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "vrm") { models.append((name, url)) }
        }
        for item in (env["NL_SPRING_DIAG_MODELS"] ?? "").split(separator: ":") where !item.isEmpty {
            let url = URL(fileURLWithPath: String(item))
            models.append((url.deletingPathExtension().lastPathComponent, url))
        }

        let load = try GPULoad(device: device)
        var summary = "model\tcondition\tchains\trest_max_mm\trest_p95_mm\tbob_step_max_mm\n"
        for (name, url) in models {
            for busy in [false, true] {
                let model = try await VRMModel.load(from: url, device: device)
                guard model.springBone != nil else { continue }
                let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
                renderer.loadModel(model)
                if busy { load.start() }
                let result = try await Self.run(model: model, renderer: renderer)
                if busy { load.stop() }
                summary += String(
                    format: "%@\t%@\t%d\t%.3f\t%.3f\t%.3f\n", name, busy ? "gpuBusy" : "idle",
                    result.chains, result.restMax * 1000, result.restP95 * 1000, result.bobStepMax * 1000)
                renderer.clearModel()
            }
        }
        try summary.write(to: outputDir.appendingPathComponent("spring_applied.tsv"), atomically: true, encoding: .utf8)
        #expect(!summary.isEmpty)
    }

    private struct Result {
        let chains: Int
        let restMax: Float      // m, largest frame-to-frame tip move (relative to the chain root) at rest
        let restP95: Float
        let bobStepMax: Float   // m, largest frame-to-frame tip move during a gentle breathing bob
    }

    /// One app frame: animation pose, then the spring solve.
    @MainActor
    private static func frame(model: VRMModel, renderer: VRMRenderer, hips: VRMNode, base: simd_float4x4, dy: Float) {
        var local = base
        local.columns.3.y = base.columns.3.y + dy
        hips.localMatrix = local
        model.updateNodeTransforms()
        renderer.springBoneSolver.update(model: model, deltaTime: 1.0 / 60.0)
    }

    @MainActor
    private static func run(model: VRMModel, renderer: VRMRenderer) async throws -> Result {
        guard let springBone = model.springBone,
              let hipsIndex = model.humanoid?.getBoneNode(.hips), let hips = model.nodes[safe: hipsIndex]
        else { return Result(chains: 0, restMax: 0, restP95: 0, bobStepMax: 0) }
        let base = hips.localMatrix
        let chains = springBone.springs.compactMap { spring -> (VRMNode, VRMNode)? in
            guard spring.joints.count >= 2, let root = model.nodes[safe: spring.joints[0].node],
                  let tip = model.nodes[safe: spring.joints[spring.joints.count - 1].node] else { return nil }
            return (root, tip)
        }
        func snapshot() -> [SIMD3<Float>] { chains.map { $0.1.worldPosition - $0.0.worldPosition } }

        // Settle 2 s, then 3 s at rest, then 4 s of a ±8 mm bob, all at 60 Hz.
        for _ in 0..<120 {
            frame(model: model, renderer: renderer, hips: hips, base: base, dy: 0)
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        var rest: [[SIMD3<Float>]] = []
        for _ in 0..<180 {
            frame(model: model, renderer: renderer, hips: hips, base: base, dy: 0)
            rest.append(snapshot())
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        var bob: [[SIMD3<Float>]] = []
        for index in 0..<240 {
            let time = Float(index) / 60
            frame(model: model, renderer: renderer, hips: hips, base: base, dy: 0.008 * sin(2 * .pi * 0.33 * time))
            bob.append(snapshot())
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        hips.localMatrix = base

        func steps(_ frames: [[SIMD3<Float>]]) -> [Float] {
            var result: [Float] = []
            for index in 1..<frames.count {
                for chain in 0..<chains.count {
                    result.append(simd_length(frames[index][chain] - frames[index - 1][chain]))
                }
            }
            return result.sorted()
        }
        let restSteps = steps(rest)
        let bobSteps = steps(bob)
        return Result(
            chains: chains.count, restMax: restSteps.last ?? 0,
            restP95: restSteps.isEmpty ? 0 : restSteps[restSteps.count * 95 / 100],
            bobStepMax: bobSteps.last ?? 0)
    }
}

/// Keeps the GPU busy from a second queue, as llama.cpp's Metal backend does
/// while the local model generates: back-to-back ~5 ms compute dispatches.
private final class GPULoad: @unchecked Sendable {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let lock = NSLock()
    private var running = false

    init(device: MTLDevice) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void burn(device float* out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id) * 0.001;
            for (uint i = 0; i < 20000; i++) { x = sin(x) * 1.0001 + 0.5; }
            out[id] = x;
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "burn"), let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: 65_536 * 4, options: .storageModePrivate)
        else { throw CancellationError() }
        self.queue = queue
        self.buffer = buffer
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func start() {
        lock.withLock { running = true }
        for _ in 0..<3 { submit() }
    }

    func stop() {
        lock.withLock { running = false }
        queue.makeCommandBuffer().map { $0.commit(); $0.waitUntilCompleted() }
    }

    private func submit() {
        guard lock.withLock({ running }), let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 65_536, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [weak self] _ in self?.submit() }
        commandBuffer.commit()
    }
}
