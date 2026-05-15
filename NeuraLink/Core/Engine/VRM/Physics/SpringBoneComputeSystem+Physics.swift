//
// SpringBoneComputeSystem+Physics.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import Metal
import QuartzCore
import simd

extension SpringBoneComputeSystem {
    func update(model: VRMModel, deltaTime: TimeInterval) {
        guard let buffers = model.springBoneBuffers,
            let globalParams = model.springBoneGlobalParams,
            buffers.numBones > 0
        else {
            return
        }

        // Fixed timestep accumulation
        timeAccumulator += deltaTime
        let fixedDeltaTime = 1.0 / VRMConstants.Physics.substepRateHz  // Fixed update at configured rate
        let maxSubsteps = VRMConstants.Physics.maxSubstepsPerFrame

        // Calculate total substeps this frame BEFORE the loop (for interpolation)
        frameSubstepCount = min(Int(timeAccumulator / fixedDeltaTime), maxSubsteps)
        currentSubstepIndex = 0

        // Capture all target transforms where animation wants to go this frame
        // This is called ONCE per frame, not per substep
        // Captures: root positions, world bind directions, collider transforms
        if VRMConstants.Physics.enableRootInterpolation && frameSubstepCount > 0 {
            captureTargetTransforms(model: model)

            // Check for teleportation BEFORE entering substep loop
            checkTeleportationAndReset(model: model, buffers: buffers)
        }

        var stepsThisFrame = 0

        // Process fixed steps (clamped to avoid spiral-of-death)
        while timeAccumulator >= fixedDeltaTime && stepsThisFrame < maxSubsteps {
            timeAccumulator -= fixedDeltaTime
            stepsThisFrame += 1

            // Update global params with current time
            var params = globalParams
            params.windPhase += Float(fixedDeltaTime)

            // Decrement settling frames counter (allows bones to settle with gravity before inertia compensation)
            if params.settlingFrames > 0 {
                params.settlingFrames -= 1
                // Persist back to model so it carries across frames
                model.springBoneGlobalParams?.settlingFrames = params.settlingFrames
            }

            // Copy updated params to GPU
            globalParamsBuffer?.contents().copyMemory(
                from: &params, byteCount: MemoryLayout<SpringBoneGlobalParams>.stride)

            // Interpolate ALL transforms for this substep (smooth motion instead of teleportation)
            // Includes: root positions, world bind directions, collider transforms
            if VRMConstants.Physics.enableRootInterpolation && frameSubstepCount > 0 {
                // t goes from 1/N to N/N across substeps (reaches 1.0 on last substep)
                let t = Float(currentSubstepIndex + 1) / Float(frameSubstepCount)
                interpolateAllTransforms(t: t, buffers: buffers)
                currentSubstepIndex += 1
            } else {
                // Fallback: original behavior - update all at once
                updateAnimatedPositions(model: model, buffers: buffers)
            }

            // Execute XPBD pipeline
            executeXPBDStep(buffers: buffers, globalParams: params)

        }

        if timeAccumulator >= fixedDeltaTime {
            // We've reached the per-frame cap; carry a single substep forward to avoid runaway accumulation
            timeAccumulator = min(timeAccumulator, fixedDeltaTime)
        }

        // Commit all target transforms as previous for next frame's interpolation
        if VRMConstants.Physics.enableRootInterpolation && stepsThisFrame > 0 {
            commitAllTransforms()
        }

        lastUpdateTime = CACurrentMediaTime()
    }

    private func executeXPBDStep(buffers: SpringBoneBuffers, globalParams: SpringBoneGlobalParams) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let kinematicPipeline = kinematicPipeline,
            let predictPipeline = predictPipeline,
            let distancePipeline = distancePipeline,
            let collideSpheresPipeline = collideSpheresPipeline,
            let collideCapsulesPipeline = collideCapsulesPipeline,
            let collidePlanesPipeline = collidePlanesPipeline
        else {
            return
        }

        let numBones = buffers.numBones
        let threadgroupSize = MTLSize(width: 256, height: 1, depth: 1)
        let gridSize = MTLSize(width: numBones, height: 1, depth: 1)  // Exact thread count for Metal

        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        // Set buffers
        computeEncoder.setBuffer(buffers.bonePosPrev, offset: 0, index: 0)
        computeEncoder.setBuffer(buffers.bonePosCurr, offset: 0, index: 1)
        computeEncoder.setBuffer(buffers.boneParams, offset: 0, index: 2)
        computeEncoder.setBuffer(globalParamsBuffer, offset: 0, index: 3)
        computeEncoder.setBuffer(buffers.restLengths, offset: 0, index: 4)

        if let sphereColliders = buffers.sphereColliders, globalParams.numSpheres > 0 {
            computeEncoder.setBuffer(sphereColliders, offset: 0, index: 5)
        }

        if let capsuleColliders = buffers.capsuleColliders, globalParams.numCapsules > 0 {
            computeEncoder.setBuffer(capsuleColliders, offset: 0, index: 6)
        }

        if let planeColliders = buffers.planeColliders, globalParams.numPlanes > 0 {
            computeEncoder.setBuffer(planeColliders, offset: 0, index: 7)
        }

        // Bind directions for stiffness spring force (return-to-bind-pose)
        // Note: When interpolation is enabled, these are DYNAMICALLY updated each substep
        // with world-space bind directions interpolated from parent bone rotations.
        // This prevents rotational snapping during fast character turns.
        if let bindDirections = buffers.bindDirections {
            computeEncoder.setBuffer(bindDirections, offset: 0, index: 11)
        }

        // First update kinematic root bones with animated positions
        // Note: Kinematic kernel uses buffer indices 8-10 to avoid conflicts with colliders (5-7)
        if !rootBoneIndices.isEmpty,
            let animatedRootPositionsBuffer = animatedRootPositionsBuffer,
            let rootBoneIndicesBuffer = rootBoneIndicesBuffer,
            let numRootBonesBuffer = numRootBonesBuffer {
            computeEncoder.setComputePipelineState(kinematicPipeline)
            computeEncoder.setBuffer(animatedRootPositionsBuffer, offset: 0, index: 8)
            computeEncoder.setBuffer(rootBoneIndicesBuffer, offset: 0, index: 9)
            computeEncoder.setBuffer(numRootBonesBuffer, offset: 0, index: 10)
            let rootGridSize = MTLSize(width: rootBoneIndices.count, height: 1, depth: 1)
            computeEncoder.dispatchThreads(rootGridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        // Execute predict kernel (step 1: predict new tip position)
        computeEncoder.setComputePipelineState(predictPipeline)
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.memoryBarrier(scope: .buffers)

        // Distance constraint iterations (step 2: enforce bone length)
        // VRM spec: run distance constraint BEFORE collision, do not run it after
        let iterations = VRMConstants.Physics.constraintIterations
        for _ in 0..<iterations {
            computeEncoder.setComputePipelineState(distancePipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        // Collision resolution (step 3: push tips out of colliders)
        // VRM spec: collision runs AFTER distance constraint and is the FINAL step
        // This prevents distance constraint from pulling hair back into colliders
        if globalParams.numSpheres > 0 {
            computeEncoder.setComputePipelineState(collideSpheresPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        if globalParams.numCapsules > 0 {
            computeEncoder.setComputePipelineState(collideCapsulesPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        if globalParams.numPlanes > 0 {
            computeEncoder.setComputePipelineState(collidePlanesPipeline)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.memoryBarrier(scope: .buffers)
        }

        computeEncoder.endEncoding()

        simulationFrameCounter &+= 1
        let frameID = simulationFrameCounter

        commandBuffer.addCompletedHandler { [weak self, weak buffers = buffers] buffer in
            guard let self = self, let buffers = buffers else { return }

            // Check for GPU errors before reading back data
            if buffer.status == .error {
                return
            }

            self.captureCompletedPositions(from: buffers, frameID: frameID)
        }

        commandBuffer.commit()
    }

    func warmupPhysics(model: VRMModel, steps: Int = 30) {
        guard let buffers = model.springBoneBuffers,
            let globalParams = model.springBoneGlobalParams,
            buffers.numBones > 0
        else {
            return
        }

        // Step 1: Capture current animated positions for root bones
        guard let springBone = model.springBone else { return }

        var animatedPositions: [SIMD3<Float>] = []
        for spring in springBone.springs {
            if let firstJoint = spring.joints.first,
                let node = model.nodes[safe: firstJoint.node] {
                animatedPositions.append(node.worldPosition)
            }
        }

        // Step 2: Reset physics state to current animated positions (zeros velocity)
        resetPhysicsState(model: model, buffers: buffers, animatedPositions: animatedPositions)

        // Step 3: Also reset interpolation state to match
        resetInterpolationState()

        // Step 4: Run silent physics steps to let bones settle into natural hanging positions
        // This happens BEFORE the first render, so there's no visual bounce
        let warmupDeltaTime: TimeInterval = 1.0 / 60.0  // Simulate at 60fps
        for _ in 0..<steps {
            // Update animated positions (colliders, bind directions, etc.)
            updateAnimatedPositions(model: model, buffers: buffers)

            // Run one physics step
            var params = globalParams
            params.windPhase += Float(warmupDeltaTime)

            // Copy params to GPU
            globalParamsBuffer?.contents().copyMemory(
                from: &params, byteCount: MemoryLayout<SpringBoneGlobalParams>.stride)

            // Execute XPBD pipeline
            executeXPBDStep(buffers: buffers, globalParams: params)
        }

        // Wait for all GPU work to complete before proceeding
        // This ensures warmup physics is fully computed before first render
        if let finalCommandBuffer = commandQueue.makeCommandBuffer() {
            finalCommandBuffer.commit()
            finalCommandBuffer.waitUntilCompleted()
        }

        // Step 5: Final reset to zero velocity at settled positions
        // Read back the settled positions and use them as the new "rest" state
        if let bonePosCurr = buffers.bonePosCurr,
            let bonePosPrev = buffers.bonePosPrev {
            let currPtr = bonePosCurr.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: buffers.numBones)
            let prevPtr = bonePosPrev.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: buffers.numBones)

            // Set prev = curr to eliminate any residual velocity
            for i in 0..<buffers.numBones {
                prevPtr[i] = currPtr[i]
            }
        }

        // Reset time accumulator
        timeAccumulator = 0

        // Reset readback state
        snapshotLock.lock()
        latestPositionsSnapshot.removeAll(keepingCapacity: true)
        latestCompletedFrame = 0
        lastAppliedFrame = 0
        snapshotLock.unlock()

    }
}
