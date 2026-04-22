//
//  VRMRenderer+DrawCore.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import MetalKit
import QuartzCore
import simd

// MARK: - Core Draw Pass

extension VRMRenderer {
    func drawCore(
        in view: MTKView, commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        // Wait for a free uniform buffer (triple buffering sync)
        _ = inflightSemaphore.wait(timeout: .distantFuture)

        // Start frame validation
        strictValidator?.beginFrame()

        guard let model = model else {
            // No model loaded: render sky and terrain so the environment stays alive.
            drawEnvironmentFrame(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
            return
        }

        // LOCK THE MODEL: Prevent animation updates while we encode draw commands
        model.lock.lock()
        defer { model.lock.unlock() }

        guard isModelVisible else {
            // Model loaded but T-pose not yet hidden: keep environment rendering without the model.
            drawEnvironmentFrame(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
            return
        }

        // CRITICAL: Update world transforms for all nodes
        // This must be done before rendering to calculate proper positions
        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }

        // Get the next uniform buffer in the ring
        currentUniformBufferIndex = (currentUniformBufferIndex + 1) % Self.maxBufferedFrames
        guard currentUniformBufferIndex < uniformsBuffers.count else {
            inflightSemaphore.signal()
            return
        }
        let uniformsBuffer = uniformsBuffers[currentUniformBufferIndex]

        // Validate pipeline states in strict mode
        if config.strict != .off {
            do {
                try strictValidator?.validatePipelineState(
                    opaquePipelineState, name: "opaque_pipeline")
                try strictValidator?.validateUniformBuffer(
                    uniformsBuffer, requiredSize: MemoryLayout<Uniforms>.size)
                if morphTargetSystem?.morphAccumulatePipelineState == nil {
                    throw StrictModeError.missingComputeFunction(name: "morph_accumulate")
                }
            } catch {
                if config.strict == .fail {
                    inflightSemaphore.signal()
                }
            }
        } else {
            // Legacy asserts for non-strict mode
            assert(opaquePipelineState != nil, "[VRMRenderer] Opaque pipeline state is nil")
            assert(!uniformsBuffers.isEmpty, "[VRMRenderer] Uniforms buffers are empty")
            assert(
                morphTargetSystem?.morphAccumulatePipelineState != nil,
                "[VRMRenderer] Compute pipeline state is nil")
        }

        // Run compute pass for morphs BEFORE render encoder
        let morphedBuffers = applyMorphTargetsCompute(commandBuffer: commandBuffer)

        // Shadow map depth pass — must happen before the main render encoder opens
        drawShadowPass(commandBuffer: commandBuffer)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            if config.strict != .off {
                do {
                    try strictValidator?.handle(.encoderCreationFailed(type: "render"))
                } catch {
                }
            }
            return
        }

        // 1. Sky (depth test = always, no depth write — always behind everything)
        drawSky(encoder: encoder)

        // 2. Snow terrain (depth write = true — VRM renders on top)
        drawTerrain(encoder: encoder)

        // Update LookAt controller
        if let lookAtController = lookAtController, lookAtController.enabled {
            // Extract camera position from view matrix
            // The view matrix transforms world to view space, so we need the inverse
            // For a view matrix, the camera position in world space is the inverse translation
            let viewMatrixInv = viewMatrix.inverse
            let cameraPos = SIMD3<Float>(
                viewMatrixInv[3][0],
                viewMatrixInv[3][1],
                viewMatrixInv[3][2]
            )

            lookAtController.cameraPosition = cameraPos
            lookAtController.update(deltaTime: 1.0 / 60.0)  // Assume 60 FPS for now

        }

        // Update SpringBone GPU physics if enabled
        // IMPORTANT: Must be done BEFORE skinning matrix update so SpringBone transforms are included
        if enableSpringBone, model.springBone != nil {

            // Calculate actual deltaTime
            let currentTime = CACurrentMediaTime()
            let deltaTime = lastUpdateTime > 0 ? Float(currentTime - lastUpdateTime) : 1.0 / 60.0
            lastUpdateTime = currentTime

            // Clamp deltaTime to reasonable values (prevent huge jumps)
            let clampedDeltaTime = min(deltaTime, 1.0 / 30.0)  // Max 30ms per frame

            // Update temporary forces if any
            updateSpringBoneForces(deltaTime: clampedDeltaTime)

            // Run GPU physics simulation
            if let springBoneCompute = springBoneComputeSystem {
                springBoneCompute.update(model: model, deltaTime: TimeInterval(clampedDeltaTime))

                // Read back GPU positions and update node transforms
                springBoneCompute.writeBonesToNodes(model: model)

                // CRITICAL: Propagate spring bone transforms through entire hierarchy before skinning
                model.updateNodeTransforms()
            }
        }

        // Update all joint palettes before any draw calls to ensure consistent state.
        let hasSkinning = !model.skins.isEmpty
        if hasSkinning {
            skinningSystem?.beginFrame()
            for (skinIndex, skin) in model.skins.enumerated() {
                skinningSystem?.updateJointMatrices(for: skin, skinIndex: skinIndex)
            }
        }

        // We'll set the pipeline per-mesh based on whether it has a skin
        encoder.setDepthStencilState(depthStencilStates["opaque"])

        // Enable back-face culling for proper rendering
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)  // glTF uses CCW winding

        // Update uniforms with camera matrices
        uniforms.viewMatrix = viewMatrix
        uniforms.projectionMatrix = projectionMatrix

        // Use stored light directions directly (world-space lighting)
        // Camera-following lights caused washout - reverting to fixed world-space
        uniforms.lightDirection = storedLightDirections.0
        uniforms.light1Direction = storedLightDirections.1
        uniforms.light2Direction = storedLightDirections.2

        // Lighting colors are configured via setup3PointLighting() or setLight()
        // Ambient color default is set in Uniforms struct initialization
        // Get viewport size from view
        let viewportSize: CGSize
        if let dummyView = view as? DummyView {
            // DummyView's drawableSize is nonisolated, safe to access directly
            viewportSize = dummyView.drawableSize
        } else {
            // Real MTKView requires main actor isolation
            viewportSize = MainActor.assumeIsolated { view.drawableSize }
        }
        uniforms.viewportSize = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
        // Set debug mode (0=off, 1=UV, 2=hasBaseColorTexture, 3=baseColorFactor)
        uniforms.debugUVs = debugUVs

        // Calculate light normalization factor based on mode
        switch lightNormalizationMode {
        case .automatic:
            // Shader handles energy conservation internally via intensity-weighted lighting
            uniforms.lightNormalizationFactor = 1.0
        case .disabled:
            uniforms.lightNormalizationFactor = 1.0
        case .manual(let factor):
            uniforms.lightNormalizationFactor = max(0.0, factor)  // Clamp to non-negative
        }

        // Copy uniforms to the current buffer
        uniformsBuffer.contents().copyMemory(
            from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)

        // ALPHA MODE QUEUING: Collect all primitives and sort by alpha mode
        // PERFORMANCE OPTIMIZATION: Use cached render items if available
        var allItems: [RenderItem]

        if let cached = cachedRenderItems, !cacheNeedsRebuild {
            allItems = cached
        } else {
            allItems = buildRenderItems(model: model)
            cachedRenderItems = allItems
            cacheNeedsRebuild = false
        }

        let itemsToRender: [RenderItem]
        if debugSingleMesh {
            itemsToRender = allItems.isEmpty ? [] : [allItems[0]]
        } else {
            itemsToRender = allItems
        }

        // DRAW LIST BISECT: Filter by draw index if requested
        var drawIndex = 0

        for (index, item) in itemsToRender.enumerated() {
            let meshName = item.mesh.name ?? "unnamed"
            let materialName = item.materialName

            // RENDER FILTER: Skip items that don't match the filter
            if let filter = config.renderFilter {
                let shouldRender: Bool
                switch filter {
                case .mesh(let name):
                    shouldRender = meshName == name
                case .material(let name):
                    shouldRender = materialName == name
                case .primitive(let primIndex):
                    let meshPrimIndex =
                        item.mesh.primitives.firstIndex(where: { $0 === item.primitive }) ?? -1
                    shouldRender = meshPrimIndex == primIndex
                }

                if !shouldRender {
                    continue
                }
            }

            // DRAW LIST BISECT: Check if this draw should be rendered
            if let drawUntil = config.drawUntil {
                if drawIndex > drawUntil {
                    continue
                }
            }

            if let drawOnlyIndex = config.drawOnlyIndex {
                if drawIndex != drawOnlyIndex {
                    drawIndex += 1
                    continue
                }
            }

            let prim = item.primitive
            let meshPrimIndex = item.mesh.primitives.firstIndex(where: { $0 === prim }) ?? -1

            // Increment draw index for next iteration
            drawIndex += 1

            let primitive = item.primitive

            // Use effective properties from RenderItem (includes overrides)
            let materialAlphaMode = item.effectiveAlphaMode
            let isDoubleSided = item.effectiveDoubleSided

            // Contract validation: effective alpha mode should be valid
            precondition(
                ["opaque", "mask", "blend"].contains(materialAlphaMode),
                "Invalid effective alpha mode: \(materialAlphaMode)")

            // Choose pipeline based on skinning AND alpha mode
            let nodeHasSkin = item.node.skin != nil

            let meshUsesSkinning = item.primitive.hasJoints && item.primitive.hasWeights

            // A mesh needs skinning if either the node has skin OR the primitive has joint attributes
            let isSkinned = (nodeHasSkin || meshUsesSkinning) && hasSkinning

            // Select correct pipeline based on alpha mode and debug settings
            let activePipelineState: MTLRenderPipelineState?
            if debugWireframe {
                // Use wireframe pipeline for debugging (non-skinned only for now)
                activePipelineState = wireframePipelineState
            } else if materialAlphaMode == "blend" {
                // Standard 3D BLEND mode requires blending-enabled PSO
                activePipelineState = isSkinned ? skinnedBlendPipelineState : blendPipelineState
            } else {
                // Standard 3D OPAQUE and MASK modes can share the same PSO (no blending)
                activePipelineState = isSkinned ? skinnedOpaquePipelineState : opaquePipelineState
            }

            guard let pipeline = activePipelineState else {
                continue
            }

            renderAcceptedItem(
                item,
                pipeline: pipeline,
                encoder: encoder,
                model: model,
                uniformsBuffer: uniformsBuffer,
                morphedBuffers: morphedBuffers,
                hasSkinning: hasSkinning
            )
        }

        // Increment frame counter
        frameCounter += 1

        // Render outlines for MToon mode (inverted hull technique)
        renderMToonOutlines(
            encoder: encoder,
            renderItems: allItems,
            model: model
        )

        encoder.endEncoding()

        // Rain-on-glass overlay (compute water map → transparent fragment pass)
        drawRainOverlay(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)

        // End frame validation
        if config.strict != .off {
            do {
                try strictValidator?.endFrame()
            } catch {
                // Strict mode errors handled silently unless .fail which is caught elsewhere
            }
        }

        // Add command buffer completion handler for error checking and semaphore signaling
        commandBuffer.addCompletedHandler { [weak self] _ in
            // Signal that this frame's uniform buffer is available again
            self?.inflightSemaphore.signal()

            // (command buffer error checking handled by caller if needed)
        }
    }

    // MARK: - Environment-Only Frame

    /// Renders sky and terrain without a VRM model. Used while no model is loaded or while
    /// the model is still hidden (T-pose phase). Signals the inflight semaphore on completion.
    private func drawEnvironmentFrame(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        terrainRenderer?.clearShadowMapIfNeeded(commandBuffer: commandBuffer)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            inflightSemaphore.signal()
            return
        }
        drawSky(encoder: encoder)
        drawTerrain(encoder: encoder)
        encoder.endEncoding()
        drawRainOverlay(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }
    }
}
