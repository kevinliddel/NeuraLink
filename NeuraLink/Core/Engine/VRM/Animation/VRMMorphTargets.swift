//
// VRMMorphTargets.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import Metal
import QuartzCore
import simd

// MARK: - Morph Target Errors

public enum VRMMorphTargetError: Error, LocalizedError {
    case failedToCreateCommandQueue
    case failedToCreateComputePipeline(String)
    case missingShaderFunction(String)

    public var errorDescription: String? {
        switch self {
        case .failedToCreateCommandQueue:
            return "Failed to create Metal command queue"
        case .failedToCreateComputePipeline(let reason):
            return "Failed to create morph compute pipeline: \(reason)"
        case .missingShaderFunction(let name):
            return "Failed to find shader function '\(name)'"
        }
    }
}

// MARK: - Active Morph (GPU struct)

public struct ActiveMorph {
    public var index: UInt32
    public var weight: Float

    public init(index: UInt32, weight: Float) {
        self.index = index
        self.weight = weight
    }
}

// MARK: - Morph Target System

/// Morphs on the GPU: base + Σ weight × delta for the strongest active
/// targets, positions and normals alike (morph_accumulate_positions /
/// _normals). Each dispatch carries its own copy of the active set: one
/// shared buffer rewritten per primitive let every dispatch of a frame read
/// the last primitive's weights.
public class VRMMorphTargetSystem {
    private let device: MTLDevice
    private var morphedPositionBuffers: [Int: MTLBuffer] = [:]
    private var morphedNormalBuffers: [Int: MTLBuffer] = [:]

    public static let maxActiveMorphs = VRMConstants.Rendering.maxActiveMorphs
    public static let morphEpsilon = VRMConstants.Physics.morphEpsilon
    private var positionsPipeline: MTLComputePipelineState?
    private var normalsPipeline: MTLComputePipelineState?

    public enum Attribute { case positions, normals }

    /// Both compute pipelines were built.
    public var isReady: Bool { positionsPipeline != nil && normalsPipeline != nil }

    public init(device: MTLDevice) throws {
        self.device = device
        try setupComputePipelines()
    }

    private func setupComputePipelines() throws {
        var library: MTLLibrary?
        if let url = Bundle.main.url(forResource: "NeuraLinkShaders", withExtension: "metallib"),
            let lib = try? device.makeLibrary(URL: url) {
            library = lib
        } else {
            library = device.makeDefaultLibrary()
        }
        guard let validLibrary = library else {
            throw VRMMorphTargetError.failedToCreateComputePipeline("No Metal shader library available.")
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = validLibrary.makeFunction(name: name) else {
                throw VRMMorphTargetError.missingShaderFunction(name)
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw VRMMorphTargetError.failedToCreateComputePipeline(error.localizedDescription)
            }
        }
        positionsPipeline = try pipeline("morph_accumulate_positions")
        normalsPipeline = try pipeline("morph_accumulate_normals")
    }

    // MARK: - Active Set

    /// The strongest weights (at most maxActiveMorphs), largest first.
    public func buildActiveSet(weights: [Float]) -> [ActiveMorph] {
        var candidates = weights.enumerated().compactMap { (i, w) -> ActiveMorph? in
            abs(w) > VRMMorphTargetSystem.morphEpsilon
                ? ActiveMorph(index: UInt32(i), weight: w) : nil
        }
        candidates.sort { abs($0.weight) > abs($1.weight) }
        return Array(candidates.prefix(VRMMorphTargetSystem.maxActiveMorphs))
    }

    // MARK: - Morphed Output Buffers

    // Keyed by the primitive's object address. Once a model is freed, a new
    // model's primitive can reuse that address, so a cached buffer is only
    // handed out when it is big enough; and the renderer drops them all
    // when its model changes. A buffer sized for a smaller old mesh made the
    // morph pass write past its end (a mangled face after a switch).

    public func getOrCreateMorphedPositionBuffer(primitiveID: Int, vertexCount: Int) -> MTLBuffer? {
        Self.buffer(in: &morphedPositionBuffers, key: primitiveID, vertexCount: vertexCount, device: device)
    }

    public func getOrCreateMorphedNormalBuffer(primitiveID: Int, vertexCount: Int) -> MTLBuffer? {
        Self.buffer(in: &morphedNormalBuffers, key: primitiveID, vertexCount: vertexCount, device: device)
    }

    /// Forgets every morphed output buffer (the model changed).
    public func releaseMorphedBuffers() {
        morphedPositionBuffers.removeAll()
        morphedNormalBuffers.removeAll()
    }

    private static func buffer(
        in cache: inout [Int: MTLBuffer], key: Int, vertexCount: Int, device: MTLDevice
    ) -> MTLBuffer? {
        let length = vertexCount * MemoryLayout<SIMD3<Float>>.stride
        if let buffer = cache[key], buffer.length >= length { return buffer }
        let buffer = device.makeBuffer(length: max(length, 16), options: .storageModePrivate)
        cache[key] = buffer
        return buffer
    }

    // MARK: - GPU Compute

    /// Encodes base + Σ weight × delta for `activeSet` into `output`
    /// (normals come out normalized).
    public func accumulate(
        _ attribute: Attribute, base: MTLBuffer, deltas: MTLBuffer, output: MTLBuffer,
        vertexCount: Int, morphCount: Int, activeSet: [ActiveMorph], commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard !activeSet.isEmpty,
            let pipelineState = attribute == .positions ? positionsPipeline : normalsPipeline,
            let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setBuffer(base, offset: 0, index: 0)
        computeEncoder.setBuffer(deltas, offset: 0, index: 1)
        activeSet.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress { computeEncoder.setBytes(address, length: bytes.count, index: 2) }
        }
        var vCount = UInt32(vertexCount)
        var mCount = UInt32(morphCount)
        var aCount = UInt32(activeSet.count)
        computeEncoder.setBytes(&vCount, length: MemoryLayout<UInt32>.size, index: 3)
        computeEncoder.setBytes(&mCount, length: MemoryLayout<UInt32>.size, index: 4)
        computeEncoder.setBytes(&aCount, length: MemoryLayout<UInt32>.size, index: 5)
        computeEncoder.setBuffer(output, offset: 0, index: 6)

        let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let groups = MTLSize(width: (vertexCount + 255) / 256, height: 1, depth: 1)
        computeEncoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        computeEncoder.endEncoding()
        return true
    }
}

// MARK: - Morph Target Data

public struct VRMMorphTarget {
    public let name: String
    public var positionDeltas: [SIMD3<Float>]?
    public var normalDeltas: [SIMD3<Float>]?
    public var tangentDeltas: [SIMD3<Float>]?

    public init(name: String) { self.name = name }
}
