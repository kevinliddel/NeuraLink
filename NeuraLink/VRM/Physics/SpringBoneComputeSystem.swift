//
// SpringBoneComputeSystem.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import Metal
import QuartzCore  // For CACurrentMediaTime
import simd

/// GPU-accelerated SpringBone physics system using XPBD (Extended Position-Based Dynamics)
final class SpringBoneComputeSystem: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var kinematicPipeline: MTLComputePipelineState?
    var predictPipeline: MTLComputePipelineState?
    var distancePipeline: MTLComputePipelineState?
    var collideSpheresPipeline: MTLComputePipelineState?
    var collideCapsulesPipeline: MTLComputePipelineState?
    var collidePlanesPipeline: MTLComputePipelineState?

    var globalParamsBuffer: MTLBuffer?
    var animatedRootPositionsBuffer: MTLBuffer?
    var rootBoneIndicesBuffer: MTLBuffer?
    var numRootBonesBuffer: MTLBuffer?
    var rootBoneIndices: [UInt32] = []
    var timeAccumulator: TimeInterval = 0
    var lastUpdateTime: TimeInterval = 0

    // Store bind-pose direction for each bone (in parent's local space)
    // Direction from current node to child node (current→child)
    var boneBindDirections: [SIMD3<Float>] = []

    // Store rest lengths on CPU for physics reset (mirrors GPU buffer)
    var cpuRestLengths: [Float] = []

    // Store parent indices for each bone (for kinematic position calculation)
    var cpuParentIndices: [Int] = []

    // Teleportation detection
    var lastRootPositions: [SIMD3<Float>] = []
    let teleportationThreshold: Float = 1.0

    // Interpolation state for smooth substep updates (prevents temporal aliasing / "hair explosion")
    var previousRootPositions: [SIMD3<Float>] = []
    var targetRootPositions: [SIMD3<Float>] = []
    var frameSubstepCount: Int = 0
    var currentSubstepIndex: Int = 0

    // World bind direction interpolation (prevents rotational explosions during fast turns)
    var previousWorldBindDirections: [SIMD3<Float>] = []
    var targetWorldBindDirections: [SIMD3<Float>] = []

    // Collider transform interpolation (prevents collision snapping during fast rotations)
    var previousSphereColliders: [SphereCollider] = []
    var targetSphereColliders: [SphereCollider] = []
    var previousCapsuleColliders: [CapsuleCollider] = []
    var targetCapsuleColliders: [CapsuleCollider] = []
    var previousPlaneColliders: [PlaneCollider] = []
    var targetPlaneColliders: [PlaneCollider] = []

    // Cached model scale for scale-aware thresholds
    var cachedModelScale: Float = 1.0

    /// Flag to request physics state reset on next update (e.g., when returning to idle)
    var requestPhysicsReset = false

    // MARK: - Runtime Collider Radius Overrides

    /// Runtime overrides for sphere collider radii (index -> radius)
    /// Used to dynamically adjust collision boundaries, e.g., to prevent hair clipping
    var sphereColliderRadiusOverrides: [Int: Float] = [:]

    /// Sets a runtime radius override for a sphere collider
    func setSphereColliderRadius(index: Int, radius: Float) {
        sphereColliderRadiusOverrides[index] = radius
    }

    /// Clears a sphere collider radius override, reverting to the original value
    func clearSphereColliderRadiusOverride(index: Int) {
        sphereColliderRadiusOverrides.removeValue(forKey: index)
    }

    /// Clears all sphere collider radius overrides
    func clearAllColliderRadiusOverrides() {
        sphereColliderRadiusOverrides.removeAll()
    }

    // Readback + synchronization (protected by snapshotLock)
    let snapshotLock = NSLock()
    var latestPositionsSnapshot: [SIMD3<Float>] = []
    var simulationFrameCounter: UInt64 = 0
    var latestCompletedFrame: UInt64 = 0
    var lastAppliedFrame: UInt64 = 0

    init(device: MTLDevice) throws {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        // Load compute shaders from pre-compiled .metallib
        var library: MTLLibrary?

        // Attempt 1: Load from default library (if shaders were pre-compiled into app)
        library = device.makeDefaultLibrary()
        if let lib = library {
            let hasKinematic = lib.makeFunction(name: "springBoneKinematic") != nil
            let hasPredict = lib.makeFunction(name: "springBonePredict") != nil
            let hasDistance = lib.makeFunction(name: "springBoneDistance") != nil
            let hasCollide = lib.makeFunction(name: "springBoneCollideSpheres") != nil

            if !(hasKinematic && hasPredict && hasDistance && hasCollide) {
                library = nil  // Missing functions, try .metallib
            }
        }

        // Attempt 2: Load from main bundle if needed (fallback)
        if library == nil {
            if let url = Bundle.main.url(
                forResource: "VRMMetalKitShaders", withExtension: "metallib") {
                do {
                    library = try device.makeLibrary(URL: url)
                } catch {
                    // Failed to load metallib, library remains nil
                }
            }
        }

        guard let library = library else {
            throw SpringBoneError.failedToLoadShaders
        }

        guard let kinematicFunction = library.makeFunction(name: "springBoneKinematic"),
            let predictFunction = library.makeFunction(name: "springBonePredict"),
            let distanceFunction = library.makeFunction(name: "springBoneDistance"),
            let collideSpheresFunction = library.makeFunction(name: "springBoneCollideSpheres"),
            let collideCapsulesFunction = library.makeFunction(name: "springBoneCollideCapsules"),
            let collidePlanesFunction = library.makeFunction(name: "springBoneCollidePlanes")
        else {
            throw SpringBoneError.failedToLoadShaders
        }

        kinematicPipeline = try device.makeComputePipelineState(function: kinematicFunction)
        predictPipeline = try device.makeComputePipelineState(function: predictFunction)
        distancePipeline = try device.makeComputePipelineState(function: distanceFunction)
        collideSpheresPipeline = try device.makeComputePipelineState(
            function: collideSpheresFunction)
        collideCapsulesPipeline = try device.makeComputePipelineState(
            function: collideCapsulesFunction)
        collidePlanesPipeline = try device.makeComputePipelineState(function: collidePlanesFunction)

        // Create global params buffer
        globalParamsBuffer = device.makeBuffer(
            length: MemoryLayout<SpringBoneGlobalParams>.stride, options: [.storageModeShared])
    }

    func clamp(_ value: Float, _ min: Float, _ max: Float) -> Float {
        return Swift.max(min, Swift.min(max, value))
    }
}

enum SpringBoneError: Error {
    case failedToLoadShaders
    case invalidBoneData
    case bufferAllocationFailed
}
