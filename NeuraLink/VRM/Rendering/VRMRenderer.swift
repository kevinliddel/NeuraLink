//
//  VRMRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import MetalKit
import QuartzCore
import simd

/// VRMRenderer manages the rendering pipeline for VRM models using Metal.
public final class VRMRenderer: NSObject, @unchecked Sendable {
    // OPTIMIZATION: Numeric key for morph buffer dictionary (avoids string interpolation)
    typealias MorphKey = UInt64

    // Helper wrapper to capture Metal buffers in @Sendable closures
    private final class SendableMTLBuffer: @unchecked Sendable {
        let buffer: MTLBuffer
        init(_ buffer: MTLBuffer) { self.buffer = buffer }
    }
    // Metal resources
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    // Pipeline states for different alpha modes (non-skinned)
    var opaquePipelineState: MTLRenderPipelineState?  // OPAQUE/MASK (no blending)
    var blendPipelineState: MTLRenderPipelineState?  // BLEND (blending enabled)
    var wireframePipelineState: MTLRenderPipelineState?  // WIREFRAME (debug mode)

    // Pipeline states for different alpha modes (skinned)
    var skinnedOpaquePipelineState: MTLRenderPipelineState?  // OPAQUE/MASK (no blending)
    var skinnedBlendPipelineState: MTLRenderPipelineState?  // BLEND (blending enabled)

    // Pipeline states for alpha-to-coverage (MASK materials with MSAA)
    var maskAlphaToCoveragePipelineState: MTLRenderPipelineState?  // Non-skinned
    var skinnedMaskAlphaToCoveragePipelineState: MTLRenderPipelineState?  // Skinned

    // Multisample texture for MSAA render targets
    var multisampleTexture: MTLTexture?

    /// Returns true if multisampling is enabled (sampleCount > 1)
    var usesMultisampling: Bool { config.sampleCount > 1 }

    // MARK: - Depth Bias

    /// Calculator for material-specific depth bias values
    ///
    /// Depth bias resolves true Z-fighting between coplanar surfaces
    /// by pushing fragments toward the camera in depth buffer space.
    public lazy var depthBiasCalculator: DepthBiasCalculator = {
        DepthBiasCalculator(scale: config.depthBiasScale)
    }()

    // MARK: - Configuration

    /// Renderer configuration including strict mode validation level.
    ///
    /// Use `.warn` during development to catch issues, `.off` in production for performance.
    public var config = RendererConfig(strict: .off)
    var strictValidator: StrictValidator?

    /// The VRM model to render. Set via `loadModel(_:)`.
    public var model: VRMModel?

    /// Controls whether model geometry is drawn. False hides T-pose until first animation frame.
    var isModelVisible: Bool = false

    // MARK: - Debug Options

    /// Debug UV visualization mode.
    public var debugUVs: Int32 = 0

    /// Enable wireframe rendering mode for debugging geometry.
    public var debugWireframe: Bool = false

    // MARK: - 2.5D Rendering Mode

    /// Light normalization mode for multi-light setups
    public enum LightNormalizationMode {
        case automatic  // Auto-normalize when total intensity > 1.0 (default)
        case disabled  // No normalization (naive additive, for testing)
        case manual(Float)  // Custom normalization factor
    }

    /// Current light normalization mode
    public var lightNormalizationMode: LightNormalizationMode = .automatic

    /// Stored light directions (world-space, shader negates for NdotL calculation)
    /// VRM models face -Z after rotation. For front lighting, use positive Z direction.
    var storedLightDirections: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = (
        SIMD3<Float>(0.2, 0.3, 0.9),  // Key light: front with slight right/above
        SIMD3<Float>(-0.3, 0.1, 0.9),  // Fill light: front-left
        SIMD3<Float>(0.0, -0.5, -0.85)  // Rim light: from behind/above
    )

    /// Orthographic camera height in world units
    public var orthoSize: Float = 1.7 {
        didSet {
            if orthoSize <= 0 {
                orthoSize = max(0.1, orthoSize)
            }
        }
    }

    /// Global outline width scale factor.
    /// Multiplies per-material outline widths. Default (0.02) preserves material values.
    /// Set to 0 to disable all outlines.
    public var outlineWidth: Float = 0.02 {
        didSet {
            if outlineWidth < 0 {
                outlineWidth = max(0, outlineWidth)
            }
        }
    }

    /// Global outline color override (RGB). When non-zero, overrides per-material outline colors.
    /// Expression-driven overrides take precedence over this value.
    public var outlineColor: SIMD3<Float> = SIMD3<Float>(0, 0, 0)

    /// Use orthographic projection instead of perspective
    public var useOrthographic: Bool = false

    /// Field of view in degrees (for perspective projection)
    public var fovDegrees: Float = 60.0 {
        didSet {
            if fovDegrees <= 0 || fovDegrees >= 180 {
                fovDegrees = max(1.0, min(179.0, fovDegrees))
            }
        }
    }

    // Pipeline states for MToon outline rendering
    var mtoonOutlinePipelineState: MTLRenderPipelineState?
    var mtoonSkinnedOutlinePipelineState: MTLRenderPipelineState?

    // Sprite Cache System for multi-character optimization
    public var spriteCacheSystem: SpriteCacheSystem?

    /// Detail level for rendering (controls sprite cache usage)
    public enum DetailLevel {
        case full3D  // Always render full 3D
        case cachedSprite  // Use sprite cache when available
        case hybrid  // Priority-based (main speaker = 3D, background = cached)
    }

    /// Current detail level
    public var detailLevel: DetailLevel = .full3D

    // Character priority system for hybrid rendering
    public var prioritySystem: CharacterPrioritySystem?

    // Sky background renderer
    var skyRenderer: SkyRenderer?

    // Rain-on-glass overlay
    var rainRenderer: RainRenderer?

    // Snow terrain + shadow map renderer
    var terrainRenderer: TerrainRenderer?

    // Sprite rendering pipeline
    var spritePipelineState: MTLRenderPipelineState?
    var spriteVertexBuffer: MTLBuffer?
    var spriteIndexBuffer: MTLBuffer?
    let spriteIndexCount: Int = 6

    // Skinning
    var skinningSystem: VRMSkinningSystem?

    // Morph Targets
    public var morphTargetSystem: VRMMorphTargetSystem?
    public var expressionController: VRMExpressionController?

    // LookAt
    public var lookAtController: VRMLookAtController?

    // MARK: - Spring Bone Physics

    var springBoneComputeSystem: SpringBoneComputeSystem?

    /// Enables GPU-accelerated spring bone physics simulation.
    public var enableSpringBone: Bool = false

    /// Quality preset for spring bone physics simulation.
    public var springBoneQuality: VRMConstants.SpringBoneQuality = .ultra

    var lastUpdateTime: CFTimeInterval = 0
    var temporaryGravity: SIMD3<Float>?
    var temporaryWind: SIMD3<Float>?
    var forceTimer: Float = 0

    // OPTIMIZATION: Static zero weights array (avoids allocation per primitive)
    static let zeroMorphWeights = [Float](repeating: 0, count: 8)

    // Triple-buffered uniforms for avoiding CPU-GPU sync
    static let maxBufferedFrames = VRMConstants.Rendering.maxBufferedFrames
    var uniformsBuffers: [MTLBuffer] = []
    var currentUniformBufferIndex = 0
    var uniforms = Uniforms()
    let inflightSemaphore: DispatchSemaphore

    // MARK: - Camera

    /// View matrix (camera transform). Set this each frame before calling `draw()`.
    public var viewMatrix = matrix_identity_float4x4

    /// Projection matrix (perspective or orthographic). Set this each frame or when viewport changes.
    public var projectionMatrix = matrix_identity_float4x4

    // MARK: - Debug Flags

    /// Disables back-face culling (shows both sides of all triangles).
    public var disableCulling = false

    /// Renders all materials as solid white color for debugging.
    public var solidColorMode = false

    /// Disables skeletal skinning (shows bind pose).
    public var disableSkinning = false

    /// Disables morph target/blend shape deformation.
    public var disableMorphs = false

    /// Renders only the first mesh for debugging.
    public var debugSingleMesh = false

    // Frame counter for debug logging
    var frameCounter = 0

    // PERFORMANCE OPTIMIZATION: Cached render items to avoid rebuilding every frame
    var cachedRenderItems: [RenderItem]?
    var cacheNeedsRebuild = true

    // RENDER ITEM: Structure for sorting and rendering primitives
    struct RenderItem {
        let node: VRMNode
        let mesh: VRMMesh
        let primitive: VRMPrimitive
        let alphaMode: String  // Original material alpha mode
        let materialName: String
        let meshIndex: Int
        var effectiveAlphaMode: String  // Override-able alpha mode
        var effectiveDoubleSided: Bool  // Override-able double sided
        var effectiveAlphaCutoff: Float  // Override-able alpha cutoff for MASK mode
        var faceCategory: String?  // Face sub-category: skin, eyebrow, eyeline, eye, highlight

        // OPTIMIZATION: Cached lowercased strings to avoid repeated allocations
        let materialNameLower: String
        let nodeNameLower: String
        let meshNameLower: String
        let isFaceMaterial: Bool
        let isEyeMaterial: Bool

        // OPTIMIZATION: Render order for single-array sorting (avoids concatenation)
        var renderOrder: Int  // 0=opaque, 1=faceSkin, 2=faceEyebrow, 3=faceEyeline, 4=mask, 5=faceEye, 6=faceHighlight, 7=blend

        // VRM material renderQueue for primary sorting (computed from base + offset)
        // OPAQUE base=2000, MASK base=2450, BLEND base=3000
        let materialRenderQueue: Int

        // Scene graph order for stable tie-breaking in sort (global)
        let primitiveIndex: Int

        // Per-mesh primitive index for morph buffer lookup (matches compute pass key)
        let primIdxInMesh: Int
    }

    // State caching to reduce allocations
    var depthStencilStates: [String: MTLDepthStencilState] = [:]
    var samplerStates: [String: MTLSamplerState] = [:]
    var lastPipelineState: MTLRenderPipelineState?
    var lastMaterialId: Int = -1
    // Dummy buffer to satisfy Metal validation when morphs are not used
    var emptyFloat3Buffer: MTLBuffer?

    // MARK: - MSAA / Drawable Size

    /// Current drawable size for MSAA texture management
    var currentDrawableSize: CGSize = .zero

    /// Current debug mode (0 = normal, 1-16 = various debug visualizations)
    var currentDebugMode: Int = 0

    public init(device: MTLDevice, config: RendererConfig = RendererConfig(strict: .off)) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.config = config
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
        self.inflightSemaphore = DispatchSemaphore(value: Self.maxBufferedFrames)

        // Initialize sprite cache system for multi-character optimization
        self.spriteCacheSystem = SpriteCacheSystem(device: device, commandQueue: commandQueue)

        // Initialize character priority system
        self.prioritySystem = CharacterPrioritySystem()

        super.init()

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
                // This zeros velocity and runs silent physics steps to settle bones
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
