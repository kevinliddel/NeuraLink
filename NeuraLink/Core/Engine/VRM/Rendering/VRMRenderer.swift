//
//  VRMRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import MetalKit
import UIKit
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
    var multisampleDepthTexture: MTLTexture?
    // Avatar self-shadows (VRMRenderer+AvatarShadow).
    var avatarShadowMap: MTLTexture?
    var avatarShadowPipeline: MTLRenderPipelineState?
    var avatarShadowDepthState: MTLDepthStencilState?
    var avatarShadowSampler: MTLSamplerState?
    var avatarShadowWhiteTexture: MTLTexture?
    var avatarShadowPlaceholderBuffer: MTLBuffer?
    var avatarShadowParams = AvatarShadowParams()
    /// Off on the minimal pressure tier (RuntimePressurePolicy).
    var avatarSelfShadowsEnabled = true
    /// The skinned pipelines' vertex layout, reused by the shadow pass.
    var skinnedVertexDescriptor: MTLVertexDescriptor?
    /// Start of the material clock (MToon UV animation).
    let materialClockStart = CACurrentMediaTime()
    /// Fixed material time for render tests; nil = the clock.
    var materialTimeOverride: Float?
    /// Seconds on the material clock.
    var materialTime: Float { materialTimeOverride ?? Float(CACurrentMediaTime() - materialClockStart) }

    /// Returns true if multisampling is enabled (sampleCount > 1)
    var usesMultisampling: Bool { config.sampleCount > 1 }

    // MARK: - Configuration

    /// Renderer configuration including strict mode validation level.
    ///
    /// Use `.warn` during development to catch issues, `.off` in production for performance.
    public var config = RendererConfig(strict: .off)
    var strictValidator: StrictValidator?

    /// The VRM model to render. Set via `loadModel(_:)`.
    public var model: VRMModel?

    /// Character-customization overlay (per-material recolour + texture
    /// overrides). Reset on every loadModel/clearModel; see
    /// docs/CHARACTER_CUSTOMIZATION.md.
    public let appearanceLayer = AppearanceMaterialLayer()

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
    /// Multiplier on the rain intensity the simulations receive; the scene
    /// state lowers it under thermal or power pressure.
    var rainBudgetScale: Float = 1

    // World-space 3D rain
    var rainWorldRenderer: RainWorldRenderer?

    // Snow terrain + shadow map renderer
    var terrainRenderer: TerrainRenderer?

    // Active environment mesh (only the selected one is loaded at a time)
    var environmentRenderer: EnvironmentRenderer?

    // Id of the environment currently held by `environmentRenderer`. Drives the
    // lazy reload when the user switches environments at runtime.
    var loadedEnvironmentName: String?

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

    let springBoneSolver = SpringBoneSolver()

    /// Enables spring bone physics (hair, skirts, accessories).
    public var enableSpringBone: Bool = false

    var lastUpdateTime: CFTimeInterval = 0
    
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

    // Frame capture (VRMRenderer+Capture.swift)
    let captureLock = NSLock()
    var pendingCapture: (@Sendable (UIImage?) -> Void)?

    // PERFORMANCE OPTIMIZATION: Cached render items to avoid rebuilding every frame
    var cachedRenderItems: [RenderItem]?
    var cacheNeedsRebuild = true

    /// One primitive to draw, with the material settings the draw needs.
    /// Everything comes from the material as authored (alpha mode, culling,
    /// render queue); nothing is inferred from names.
    struct RenderItem {
        let node: VRMNode
        let mesh: VRMMesh
        let primitive: VRMPrimitive
        let materialName: String
        let meshIndex: Int
        /// "opaque", "mask" or "blend".
        let alphaMode: String
        let doubleSided: Bool
        let alphaCutoff: Float
        /// VRM 1.0 base + offset, or the 0.x Unity queue.
        let materialRenderQueue: Int
        /// TransparentWithZWrite (VRM 1.0 flag or 0.x BlendMode 3 / _ZWrite):
        /// BLEND that still writes depth, so layered cloth occludes instead
        /// of double-blending.
        let transparentZWrite: Bool
        /// Scene-graph order across the model (stable sort tie-break).
        let primitiveIndex: Int
        /// Index within the mesh (morph buffer key, as the compute pass).
        let primIdxInMesh: Int
        /// Centre of the triangles this primitive draws, in the mesh's
        /// space: the transparent sort's distance point.
        let boundsCentre: SIMD3<Float>
    }

    // State caching to reduce allocations
    var depthStencilStates: [String: MTLDepthStencilState] = [:]
    var samplerStates: [String: MTLSamplerState] = [:]
    var lastPipelineState: MTLRenderPipelineState?
    var lastMaterialId: Int = -1
    // State tracking to avoid redundant Metal calls
    var lastCullMode: MTLCullMode?
    var lastFrontFacing: MTLWinding?
    var lastDepthBias: (Float, Float, Float)?
    var lastDepthStencilState: MTLDepthStencilState?
    var lastTextureIds: [Int: MTLTexture] = [:] // index -> texture
    // Dummy buffer to satisfy Metal validation when morphs are not used
    var emptyFloat3Buffer: MTLBuffer?

    // MARK: - MSAA / Drawable Size

    /// Current drawable size for MSAA texture management
    var currentDrawableSize: CGSize = .zero

    /// Current debug mode (0 = normal, 1-16 = various debug visualizations)
    var currentDebugMode: Int = 0

    init(device: MTLDevice, internal: (), config: RendererConfig) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.config = config
        self.inflightSemaphore = DispatchSemaphore(value: Self.maxBufferedFrames)
        super.init()
    }
}
