//
//  RendererContext.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import simd

/// Shared protocol for renderer subsystems that participate in the draw loop.
protocol RenderingSystem: AnyObject {
    func configure(with context: RendererBootstrapContext) throws
    func prepareFrame(_ context: FrameUpdateContext)
    func encode(_ context: RenderPassContext) throws
}

extension RenderingSystem {
    func configure(with context: RendererBootstrapContext) throws {}
    func prepareFrame(_ context: FrameUpdateContext) {}
    func encode(_ context: RenderPassContext) throws {}
}

/// Immutable data passed to systems during construction.
struct RendererBootstrapContext {
    let device: MTLDevice
    let config: RendererConfig
    let strictValidator: StrictValidator?
}

/// Per-frame data shared across systems before encoding command buffers.
struct FrameUpdateContext {
    var deltaTime: Float
    var model: VRMModel?
    var viewMatrix: simd_float4x4
    var projectionMatrix: simd_float4x4
    var debugFlags: DebugFlags

    init(
        deltaTime: Float,
        model: VRMModel?,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        debugFlags: DebugFlags = DebugFlags()
    ) {
        self.deltaTime = deltaTime
        self.model = model
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.debugFlags = debugFlags
    }

    struct DebugFlags {
        var wireframe: Bool
        var showUVs: Bool

        init(wireframe: Bool = false, showUVs: Bool = false) {
            self.wireframe = wireframe
            self.showUVs = showUVs
        }
    }
}

/// Context passed to systems while encoding a specific render pass.
struct RenderPassContext {
    let commandBuffer: MTLCommandBuffer
    let encoder: MTLRenderCommandEncoder
    let uniformsBuffer: MTLBuffer
}
