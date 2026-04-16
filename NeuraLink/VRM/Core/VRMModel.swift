//
// VRMModel.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import Metal
import simd

/// VRMModel represents a loaded VRM avatar with all its data, nodes, meshes, and materials.
public class VRMModel: @unchecked Sendable {
    // MARK: - Thread Safety
    let lock = NSLock()

    /// Execute a closure while holding the model's lock
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Properties

    /// The VRM specification version of this model (0.0 or 1.0).
    public let specVersion: VRMSpecVersion

    /// Model metadata including title, author, license, and usage permissions.
    public let meta: VRMMeta

    /// Returns `true` if this model uses VRM 0.0 format.
    ///
    /// VRM 0.0 uses Unity's left-handed coordinate system while VRM 1.0 uses glTF's right-handed system.
    /// This affects coordinate conversion when playing VRMA animations.
    public var isVRM0: Bool {
        return specVersion == .v0_0
    }

    /// Humanoid bone mapping for this avatar.
    ///
    /// Maps standard VRM bones (hips, spine, head, arms, legs, etc.) to node indices.
    /// Use `humanoid?.getBoneNode(.hips)` to get a specific bone's node index.
    public var humanoid: VRMHumanoid?

    /// First-person rendering configuration.
    ///
    /// Defines which meshes should be visible in first-person vs third-person cameras.
    public var firstPerson: VRMFirstPerson?

    /// Eye gaze (look-at) configuration.
    ///
    /// Defines how the avatar's eyes track a target point, including range limits.
    public var lookAt: VRMLookAt?

    /// Facial expressions (blend shapes) for this avatar.
    ///
    /// Contains both preset expressions (happy, angry, blink, etc.) and custom expressions.
    /// Use `VRMExpressionController` to animate expressions at runtime.
    public var expressions: VRMExpressions?

    /// Spring bone physics configuration for hair, clothing, and accessories.
    ///
    /// Defines physics chains, stiffness, gravity, and colliders. Physics simulation
    /// is performed on the GPU via `SpringBoneComputeSystem`.
    public var springBone: VRMSpringBone?

    /// VRM 0.x MToon material properties stored at document level.
    public var vrm0MaterialProperties: [VRM0MaterialProperty] = []

    /// Node constraints for twist bones and other constrained nodes.
    ///
    /// VRM 1.0 parses these from VRMC_node_constraint extension.
    /// VRM 0.0 synthesizes constraints automatically from humanoid bone definitions.
    public var nodeConstraints: [VRMNodeConstraint] = []

    // MARK: - glTF Data

    /// The underlying glTF document structure.
    public var gltf: GLTFDocument

    /// All meshes in the model, each containing one or more primitives.
    public var meshes: [VRMMesh] = []

    /// All materials used by this model (MToon, PBR, or unlit).
    public var materials: [VRMMaterial] = []

    /// All textures loaded for this model.
    public var textures: [VRMTexture] = []

    /// All nodes in the scene graph hierarchy.
    ///
    /// Nodes form a tree structure via `parent` and `children` properties.
    /// Each node has local and world transforms that can be animated.
    public var nodes: [VRMNode] = []

    /// Skin data for skeletal animation (joint matrices, inverse bind matrices).
    public var skins: [VRMSkin] = []

    // MARK: - Runtime State

    /// Base URL for resolving relative resource paths (set during loading).
    public var baseURL: URL?

    /// Metal device used for GPU resources. Required for rendering and physics.
    public var device: MTLDevice?

    /// GPU buffers for spring bone physics simulation.
    public var springBoneBuffers: SpringBoneBuffers?

    /// Global parameters for spring bone physics (gravity, wind, substeps).
    public var springBoneGlobalParams: SpringBoneGlobalParams?

    // PERFORMANCE: Pre-computed node lookup table (normalized names)
    var nodeLookupTable: [String: VRMNode] = [:]

    // MARK: - Initialization

    public init(
        specVersion: VRMSpecVersion,
        meta: VRMMeta,
        humanoid: VRMHumanoid?,
        gltf: GLTFDocument
    ) {
        self.specVersion = specVersion
        self.meta = meta
        self.humanoid = humanoid
        self.gltf = gltf
    }

    // MARK: - Loading

    /// Loads a VRM model from a file URL with progress and cancellation support.
    public static func load(
        from url: URL,
        device: MTLDevice? = nil,
        options: VRMLoadingOptions = .default
    ) async throws -> VRMModel {
        let context = await VRMLoadingContext(options: options)

        await context.updatePhase(.parsingGLTF, progress: 0.0)

        let data = try Data(contentsOf: url)
        try await context.checkCancellation()

        await context.updatePhase(.parsingGLTF, progress: 1.0)

        let model = try await load(
            from: data,
            filePath: url.path,
            device: device,
            context: context
        )
        // Store the base URL for loading external resources
        model.baseURL = url.deletingLastPathComponent()
        return model
    }

    /// Loads a VRM model from raw data.
    public static func load(from data: Data, filePath: String? = nil, device: MTLDevice? = nil)
        async throws -> VRMModel
    {
        try await load(from: data, filePath: filePath, device: device, context: nil)
    }

    /// Internal loading method with context for progress and cancellation.
    private static func load(
        from data: Data,
        filePath: String? = nil,
        device: MTLDevice? = nil,
        context: VRMLoadingContext?
    ) async throws -> VRMModel {
        let parser = GLTFParser()
        let (document, binaryData) = try parser.parse(data: data, filePath: filePath)
        try await context?.checkCancellation()

        // Check for VRM 1.0 (VRMC_vrm) or VRM 0.0 (VRM)
        let vrmExtension = document.extensions?["VRMC_vrm"] ?? document.extensions?["VRM"]
        guard let vrmExtension = vrmExtension else {
            throw VRMError.missingVRMExtension(
                filePath: filePath,
                suggestion:
                    "Ensure this file is a VRM model exported with proper VRM extensions. If it's a regular glTF/GLB file, convert it to VRM format using VRM exporter tools."
            )
        }

        await context?.updatePhase(.parsingVRMExtension, progress: 0.5)

        let vrmParser = VRMExtensionParser()
        let model = try vrmParser.parseVRMExtension(
            vrmExtension, document: document, filePath: filePath)
        model.device = device

        await context?.updatePhase(.parsingVRMExtension, progress: 1.0)

        // Load resources with buffer data
        try await model.loadResources(binaryData: binaryData, context: context)

        // Initialize SpringBone GPU system if device and spring bone data present
        if let device = device, model.springBone != nil {
            await context?.updatePhase(.initializingPhysics, progress: 0.5)
            try model.initializeSpringBoneGPUSystem(device: device)
            await context?.updatePhase(.initializingPhysics, progress: 1.0)
        }

        await context?.updatePhase(.complete, progress: 1.0)

        return model
    }
}
