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
    case activeSetBufferNotInitialized

    public var errorDescription: String? {
        switch self {
        case .failedToCreateCommandQueue:
            return "Failed to create Metal command queue"
        case .failedToCreateComputePipeline(let reason):
            return "Failed to create morph compute pipeline: \(reason)"
        case .missingShaderFunction(let name):
            return "Failed to find shader function '\(name)'"
        case .activeSetBufferNotInitialized:
            return "Active set buffer not initialized"
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

public class VRMMorphTargetSystem {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let maxMorphTargets = VRMConstants.Rendering.maxMorphTargets

    private var morphWeightsBuffer: MTLBuffer?
    private var activeSet: [ActiveMorph] = []
    private var activeSetBuffer: MTLBuffer?
    private var morphedPositionBuffers: [Int: MTLBuffer] = [:]
    private var morphedNormalBuffers: [Int: MTLBuffer] = [:]

    public static let maxActiveMorphs = VRMConstants.Rendering.maxActiveMorphs
    public static let morphEpsilon = VRMConstants.Physics.morphEpsilon
    public var morphAccumulatePipelineState: MTLComputePipelineState?

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw VRMMorphTargetError.failedToCreateCommandQueue
        }
        self.commandQueue = queue
        setupBuffers()
        try setupComputePipeline()
    }

    private func setupBuffers() {
        morphWeightsBuffer = device.makeBuffer(
            length: MemoryLayout<Float>.stride * maxMorphTargets, options: .storageModeShared)
        activeSetBuffer = device.makeBuffer(
            length: MemoryLayout<ActiveMorph>.stride * VRMMorphTargetSystem.maxActiveMorphs,
            options: .storageModeShared)
    }

    private func setupComputePipeline() throws {
        var library: MTLLibrary?
        if let url = Bundle.main.url(forResource: "VRMMetalKitShaders", withExtension: "metallib"),
            let lib = try? device.makeLibrary(URL: url)
        {
            library = lib
        } else {
            library = device.makeDefaultLibrary()
        }

        guard let validLibrary = library else {
            throw VRMMorphTargetError.failedToCreateComputePipeline(
                "No Metal shader library available.")
        }

        guard let function = validLibrary.makeFunction(name: "morph_accumulate_positions") else {
            throw VRMMorphTargetError.missingShaderFunction("morph_accumulate_positions")
        }

        do {
            morphAccumulatePipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw VRMMorphTargetError.failedToCreateComputePipeline(error.localizedDescription)
        }
    }

    // MARK: - Weights

    public func updateMorphWeights(_ weights: [Float]) {
        guard let buffer = morphWeightsBuffer else { return }
        let count = min(weights.count, maxMorphTargets)
        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: count)
        for i in 0..<count { ptr[i] = weights[i] }
    }

    public func getMorphWeightsBuffer() -> MTLBuffer? { morphWeightsBuffer }

    // MARK: - Active Set

    public func buildActiveSet(weights: [Float]) -> [ActiveMorph] {
        var candidates = weights.enumerated().compactMap { (i, w) -> ActiveMorph? in
            abs(w) > VRMMorphTargetSystem.morphEpsilon
                ? ActiveMorph(index: UInt32(i), weight: w) : nil
        }
        candidates.sort { abs($0.weight) > abs($1.weight) }
        activeSet = Array(candidates.prefix(VRMMorphTargetSystem.maxActiveMorphs))

        if let buffer = activeSetBuffer, !activeSet.isEmpty {
            let ptr = buffer.contents().bindMemory(to: ActiveMorph.self, capacity: activeSet.count)
            for (i, morph) in activeSet.enumerated() { ptr[i] = morph }
        }
        return activeSet
    }

    public func getActiveSet() -> [ActiveMorph] { activeSet }
    public func getActiveSetBuffer() -> MTLBuffer? { activeSetBuffer }
    public func getActiveCount() -> Int { activeSet.count }
    public func hasMorphsToApply() -> Bool { !activeSet.isEmpty }

    // MARK: - Morphed Output Buffers

    public func getOrCreateMorphedPositionBuffer(primitiveID: Int, vertexCount: Int) -> MTLBuffer? {
        if let buffer = morphedPositionBuffers[primitiveID] { return buffer }
        let buffer = device.makeBuffer(
            length: vertexCount * MemoryLayout<SIMD3<Float>>.stride, options: .storageModePrivate)
        morphedPositionBuffers[primitiveID] = buffer
        return buffer
    }

    public func getOrCreateMorphedNormalBuffer(primitiveID: Int, vertexCount: Int) -> MTLBuffer? {
        if let buffer = morphedNormalBuffers[primitiveID] { return buffer }
        let buffer = device.makeBuffer(
            length: vertexCount * MemoryLayout<SIMD3<Float>>.stride, options: .storageModePrivate)
        morphedNormalBuffers[primitiveID] = buffer
        return buffer
    }

    // MARK: - GPU Compute

    public func applyMorphsCompute(
        basePositions: MTLBuffer,
        deltaPositions: MTLBuffer,
        outputPositions: MTLBuffer,
        vertexCount: Int,
        morphCount: Int,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        if activeSet.isEmpty {
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return false }
            blitEncoder.copy(
                from: basePositions, sourceOffset: 0,
                to: outputPositions, destinationOffset: 0,
                size: vertexCount * MemoryLayout<SIMD3<Float>>.stride)
            blitEncoder.endEncoding()
            return true
        }

        guard let activeSetBuffer,
            let pipelineState = morphAccumulatePipelineState,
            let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }

        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setBuffer(basePositions, offset: 0, index: 0)
        computeEncoder.setBuffer(deltaPositions, offset: 0, index: 1)
        computeEncoder.setBuffer(activeSetBuffer, offset: 0, index: 2)

        var vCount = UInt32(vertexCount)
        var mCount = UInt32(morphCount)
        var aCount = UInt32(activeSet.count)
        computeEncoder.setBytes(&vCount, length: MemoryLayout<UInt32>.size, index: 3)
        computeEncoder.setBytes(&mCount, length: MemoryLayout<UInt32>.size, index: 4)
        computeEncoder.setBytes(&aCount, length: MemoryLayout<UInt32>.size, index: 5)
        computeEncoder.setBuffer(outputPositions, offset: 0, index: 6)

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

// MARK: - Expression Controller

public class VRMExpressionController: @unchecked Sendable {
    private var expressions: [VRMExpressionPreset: VRMExpression] = [:]
    private var customExpressions: [String: VRMExpression] = [:]
    private var currentWeights: [VRMExpressionPreset: Float] = [:]
    private var morphTargetSystem: VRMMorphTargetSystem?
    private var animationTimer: Timer?
    private var meshMorphWeights: [Int: [Float]] = [:]
    private var materialColorOverrides: [Int: [VRMMaterialColorType: SIMD4<Float>]] = [:]
    private var baseMaterialColors: [Int: [VRMMaterialColorType: SIMD4<Float>]] = [:]

    public init() {
        for preset in VRMExpressionPreset.allCases {
            currentWeights[preset] = 0
        }
    }

    deinit {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    public func setMorphTargetSystem(_ system: VRMMorphTargetSystem) {
        morphTargetSystem = system
    }

    public func registerExpression(_ expression: VRMExpression, for preset: VRMExpressionPreset) {
        expressions[preset] = expression
    }

    public func registerCustomExpression(_ expression: VRMExpression, name: String) {
        customExpressions[name] = expression
    }

    // MARK: - Material Colors

    public func setBaseMaterialColor(
        materialIndex: Int, type: VRMMaterialColorType, color: SIMD4<Float>
    ) {
        if baseMaterialColors[materialIndex] == nil { baseMaterialColors[materialIndex] = [:] }
        baseMaterialColors[materialIndex]?[type] = color
    }

    public func getMaterialColorOverride(
        materialIndex: Int, type: VRMMaterialColorType
    ) -> SIMD4<Float>? {
        return materialColorOverrides[materialIndex]?[type]
    }

    // MARK: - Expression Weights

    public func setExpressionWeight(_ preset: VRMExpressionPreset, weight: Float) {
        currentWeights[preset] = clamp(weight, min: 0, max: 1)
        updateMorphTargets()
    }

    public func setCustomExpressionWeight(_ name: String, weight: Float) {
        if let expression = customExpressions[name] {
            applyExpression(expression, weight: clamp(weight, min: 0, max: 1))
        }
    }

    public func setCustomExpressionWeights(_ weights: [String: Float]) {
        for (name, weight) in weights {
            if let expression = customExpressions[name] {
                applyExpressionToMeshWeights(expression, weight: clamp(weight, min: 0, max: 1))
            }
        }
    }

    public func weightsForMesh(_ meshIndex: Int, morphCount: Int) -> [Float] {
        guard morphCount > 0 else { return [] }
        let arr = meshMorphWeights[meshIndex] ?? []
        if arr.count >= morphCount { return Array(arr.prefix(morphCount)) }
        return arr + Array(repeating: 0.0, count: morphCount - arr.count)
    }

    // MARK: - Presets

    public func blink(duration: Float = 0.15, completion: (@Sendable () -> Void)? = nil) {
        animateExpression(.blink, to: 1.0, duration: duration) { [weak self] in
            self?.animateExpression(.blink, to: 0.0, duration: duration, completion: completion)
        }
    }

    public func setMood(_ mood: VRMExpressionPreset, intensity: Float = 1.0) {
        let moodExpressions: [VRMExpressionPreset] = [.happy, .angry, .sad, .relaxed, .surprised]
        for expr in moodExpressions where expr != mood { setExpressionWeight(expr, weight: 0) }
        setExpressionWeight(mood, weight: intensity)
    }

    public func speak(duration: Float = 2.0) {
        animateExpression(.aa, to: 0.8, duration: duration * 0.5) { [weak self] in
            self?.animateExpression(.aa, to: 0, duration: duration * 0.5)
        }
    }

    // MARK: - Private

    private func animateExpression(
        _ preset: VRMExpressionPreset,
        to targetWeight: Float,
        duration: Float,
        completion: (@Sendable () -> Void)? = nil
    ) {
        animationTimer?.invalidate()
        let startWeight = currentWeights[preset] ?? 0
        let startTime = CACurrentMediaTime()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] timer in
            let elapsed = Float(CACurrentMediaTime() - startTime)
            let progress = min(elapsed / duration, 1.0)
            let weight = lerp(startWeight, targetWeight, progress)

            Task { @MainActor [weak self] in
                self?.setExpressionWeight(preset, weight: weight)
                if progress >= 1.0 { completion?() }
            }

            if progress >= 1.0 {
                timer.invalidate()
                self?.animationTimer = nil
            }
        }
    }

    private func updateMorphTargets() {
        meshMorphWeights.removeAll()
        materialColorOverrides.removeAll()
        for (preset, weight) in currentWeights where weight > 0 {
            if let expression = expressions[preset] {
                applyExpressionToMeshWeights(expression, weight: weight)
                applyExpressionToMaterialColors(expression, weight: weight)
            }
        }
    }

    private func applyExpressionToMaterialColors(_ expression: VRMExpression, weight: Float) {
        for bind in expression.materialColorBinds {
            let base = baseMaterialColors[bind.material]?[bind.type] ?? SIMD4<Float>(1, 1, 1, 1)
            let current = materialColorOverrides[bind.material]?[bind.type] ?? base
            let blended = current + (bind.targetValue - current) * weight
            if materialColorOverrides[bind.material] == nil {
                materialColorOverrides[bind.material] = [:]
            }
            materialColorOverrides[bind.material]?[bind.type] = blended
        }
    }

    private func applyExpressionToMeshWeights(_ expression: VRMExpression, weight: Float) {
        for bind in expression.morphTargetBinds {
            var arr = meshMorphWeights[bind.node] ?? []
            if arr.count <= bind.index {
                arr.append(contentsOf: repeatElement(0.0, count: bind.index + 1 - arr.count))
            }
            arr[bind.index] += bind.weight * weight
            meshMorphWeights[bind.node] = arr
        }
    }

    private func applyExpression(_ expression: VRMExpression, weight: Float) {
        meshMorphWeights.removeAll()
        applyExpressionToMeshWeights(expression, weight: weight)
    }
}

// MARK: - Helpers

private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    Swift.max(min, Swift.min(max, value))
}

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}
