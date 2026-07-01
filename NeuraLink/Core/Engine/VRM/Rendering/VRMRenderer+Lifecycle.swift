//
//  VRMRenderer+Lifecycle.swift
//  NeuraLink
//
//  Created by Dedicatus on 15/05/2026.
//

import Foundation
import Metal
import MetalKit
import QuartzCore

extension VRMRenderer {
    public convenience init(device: MTLDevice, config: RendererConfig = RendererConfig(strict: .off)) {
        self.init(device: device, internal: (), config: config)
        
        // Initialize systems that require the device
        self.strictValidator = StrictValidator(config: config)
        self.skinningSystem = VRMSkinningSystem(device: device)

        // Initialize morph target system (may fail if GPU compute unavailable)
        do {
            self.morphTargetSystem = try VRMMorphTargetSystem(device: device)
        } catch {
            self.morphTargetSystem = nil
        }

        self.expressionController = VRMExpressionController()
        do {
            self.springBoneComputeSystem = try SpringBoneComputeSystem(device: device)
        } catch {
            self.springBoneComputeSystem = nil
        }
        self.lookAtController = VRMLookAtController()
        
        // Initialize sprite cache system for multi-character optimization
        self.spriteCacheSystem = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        // Initialize character priority system
        self.prioritySystem = CharacterPrioritySystem()

        // Verify MToonMaterialUniforms alignment
        validateMaterialUniformAlignment()

        // Set up expression controller with morph target system
        if let morphTargetSystem = morphTargetSystem {
            self.expressionController?.setMorphTargetSystem(morphTargetSystem)
        }

        setupPipeline()
        setupSkinnedPipeline()
        setupSpritePipeline()
        setupCachedStates()
        setupTripleBuffering()
        setupSkyRenderer()
        setupTerrain()
        setupEnvironment()
    }

    /// Removes the current model from the renderer so only sky and terrain are drawn.
    func clearModel() {
        model = nil
        isModelVisible = false
        cacheNeedsRebuild = true
        cachedRenderItems = nil
        terrainRenderer?.scheduleShadowMapClear()
    }

    /// Loads a VRM model into the renderer and initializes all subsystems.
    public func loadModel(_ model: VRMModel) {
        self.model = model
        isModelVisible = false

        // PERFORMANCE: Invalidate cached render items when model changes
        cacheNeedsRebuild = true
        cachedRenderItems = nil

        if !model.skins.isEmpty {
            skinningSystem?.setupForSkins(model.skins)
        }

        // Load expressions if available
        if let expressions = model.expressions {
            // VRM 1.x morphTargetBind.node is a glTF NODE index; the renderer
            // keys weights by MESH index. Build the map once and remap before registering.
            let nodeToMesh: [Int: Int] =
                model.specVersion == .v0_0
                ? [:]
                : buildNodeToMeshMap(from: model.gltf)

            for (preset, expression) in expressions.preset {
                let expr =
                    nodeToMesh.isEmpty
                    ? expression : remapExpressionNodes(expression, map: nodeToMesh)
                expressionController?.registerExpression(expr, for: preset)
            }
            for (name, expression) in expressions.custom {
                let expr =
                    nodeToMesh.isEmpty
                    ? expression : remapExpressionNodes(expression, map: nodeToMesh)
                expressionController?.registerCustomExpression(expr, name: name)
            }
        }

        // Initialize base material colors for expression-driven material color binds
        for (materialIndex, material) in model.materials.enumerated() {
            // Store base color factor (RGBA)
            expressionController?.setBaseMaterialColor(
                materialIndex: materialIndex,
                type: .color,
                color: material.baseColorFactor
            )

            // Store emissive factor (RGB + 1.0 alpha)
            expressionController?.setBaseMaterialColor(
                materialIndex: materialIndex,
                type: .emissionColor,
                color: SIMD4<Float>(material.emissiveFactor, 1.0)
            )

            // Store MToon-specific colors if available
            if let mtoon = material.mtoon {
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .shadeColor,
                    color: SIMD4<Float>(mtoon.shadeColorFactor, 1.0)
                )
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .matcapColor,
                    color: SIMD4<Float>(mtoon.matcapFactor, 1.0)
                )
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .rimColor,
                    color: SIMD4<Float>(mtoon.parametricRimColorFactor, 1.0)
                )
                expressionController?.setBaseMaterialColor(
                    materialIndex: materialIndex,
                    type: .outlineColor,
                    color: SIMD4<Float>(mtoon.outlineColorFactor, 1.0)
                )
            }
        }

        // Initialize SpringBone GPU compute system if available
        if model.springBone != nil {
            do {
                try springBoneComputeSystem?.populateSpringBoneData(model: model)
                
                // Warm up physics to prevent initial bounce/oscillation
                springBoneComputeSystem?.warmupPhysics(model: model, steps: 30)
            } catch {
            }
        }
        
        // Initialize LookAt controller if model has lookAt data or eye bones
        if model.lookAt != nil || model.humanoid?.humanBones[.leftEye] != nil
            || model.humanoid?.humanBones[.rightEye] != nil {
            lookAtController?.setup(model: model, expressionController: expressionController)
            // Default to DISABLED to avoid misaligned eyes; can be enabled explicitly by apps
            lookAtController?.enabled = false
            lookAtController?.target = .camera
        }
    }

    // MARK: - State Caching Helpers
    
    func setDepthStencilStateCached(_ state: MTLDepthStencilState?, encoder: MTLRenderCommandEncoder) {
        if lastDepthStencilState !== state {
            encoder.setDepthStencilState(state)
            lastDepthStencilState = state
        }
    }
    
    func setCullModeCached(_ mode: MTLCullMode, encoder: MTLRenderCommandEncoder) {
        if lastCullMode != mode {
            encoder.setCullMode(mode)
            lastCullMode = mode
        }
    }
    
    func setFrontFacingCached(_ winding: MTLWinding, encoder: MTLRenderCommandEncoder) {
        if lastFrontFacing != winding {
            encoder.setFrontFacing(winding)
            lastFrontFacing = winding
        }
    }
    
    func setDepthBiasCached(_ bias: Float, slopeScale: Float, clamp: Float, encoder: MTLRenderCommandEncoder) {
        let newBias = (bias, slopeScale, clamp)
        if lastDepthBias?.0 != bias || lastDepthBias?.1 != slopeScale || lastDepthBias?.2 != clamp {
            encoder.setDepthBias(bias, slopeScale: slopeScale, clamp: clamp)
            lastDepthBias = newBias
        }
    }
    
    func setFragmentTextureCached(_ texture: MTLTexture?, index: Int, encoder: MTLRenderCommandEncoder) {
        if let texture = texture {
            if lastTextureIds[index] !== texture {
                encoder.setFragmentTexture(texture, index: index)
                lastTextureIds[index] = texture
            }
        } else {
            if lastTextureIds[index] != nil {
                encoder.setFragmentTexture(nil, index: index)
                lastTextureIds.removeValue(forKey: index)
            }
        }
    }

    // MARK: - Expression Node Remapping (VRM 1.x)

    private func buildNodeToMeshMap(from gltf: GLTFDocument) -> [Int: Int] {
        var map = [Int: Int]()
        guard let nodes = gltf.nodes else { return map }
        for (nodeIndex, node) in nodes.enumerated() {
            if let meshIndex = node.mesh { map[nodeIndex] = meshIndex }
        }
        return map
    }

    private func remapExpressionNodes(_ expression: VRMExpression, map: [Int: Int]) -> VRMExpression {
        var resolved = expression
        resolved.morphTargetBinds = expression.morphTargetBinds.compactMap { bind in
            guard let meshIndex = map[bind.node] else { return nil }
            return VRMMorphTargetBind(node: meshIndex, index: bind.index, weight: bind.weight)
        }
        return resolved
    }
}
