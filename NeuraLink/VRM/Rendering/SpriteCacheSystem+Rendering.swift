//
//  SpriteCacheSystem+Rendering.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import CoreGraphics
import Metal
import simd

// MARK: - Cache Statistics

extension SpriteCacheSystem {

    /// Cache statistics snapshot
    public struct CacheStatistics {
        public let entryCount: Int
        public let totalMemoryBytes: Int
        public let maxMemoryBytes: Int
        public let cacheHits: Int
        public let cacheMisses: Int
        public let hitRate: Float
        public let pendingRenders: Int

        public var memoryUsagePercent: Float {
            return Float(totalMemoryBytes) / Float(maxMemoryBytes) * 100
        }

        public var description: String {
            let mb = Float(totalMemoryBytes) / (1024 * 1024)
            let maxMb = Float(maxMemoryBytes) / (1024 * 1024)
            return """
                Sprite Cache Statistics:
                  Entries: \(entryCount)
                  Memory: \(String(format: "%.1f", mb)) MB / \(String(format: "%.1f", maxMb)) MB (\(String(format: "%.1f", memoryUsagePercent))%)
                  Hit Rate: \(String(format: "%.1f", hitRate * 100))%
                  Hits: \(cacheHits), Misses: \(cacheMisses)
                """
        }
    }
}

// MARK: - Rendering to Cache

extension SpriteCacheSystem {

    /// Render a character pose directly to a cached texture
    ///
    /// **Breaking Change (PR #38)**: This method now supports async GPU rendering and returns `nil`
    /// when using the async path. Use the `completion` handler to receive the cached pose when ready.
    ///
    /// **Thread Safety**: This method is thread-safe and prevents duplicate renders for the same `poseHash`.
    /// If a render is already pending for the given pose, returns `nil` immediately.
    ///
    /// ## Usage Patterns
    ///
    /// ### Synchronous (Blocking)
    /// ```swift
    /// let pose = cache.renderToCache(
    ///     characterID: "avatar1",
    ///     poseHash: hash,
    ///     waitUntilCompleted: true  // Blocks until GPU finishes
    /// ) { encoder, texture in
    ///     // Render your character here
    /// }
    /// // pose is non-nil and ready to use
    /// ```
    ///
    /// ### Asynchronous (Non-Blocking, Recommended)
    /// ```swift
    /// cache.renderToCache(
    ///     characterID: "avatar1",
    ///     poseHash: hash,
    ///     completion: { cachedPose in
    ///         // Called on callbackQueue when GPU finishes
    ///         if let pose = cachedPose {
    ///             // Use cached pose here
    ///         }
    ///     }
    /// ) { encoder, texture in
    ///     // Render your character here
    /// }
    /// // Returns nil immediately, continues on GPU
    /// ```
    ///
    /// ### Shared Command Buffer (Batching)
    /// ```swift
    /// let commandBuffer = queue.makeCommandBuffer()!
    ///
    /// // Batch multiple renders into same command buffer
    /// cache.renderToCache(characterID: "avatar1", poseHash: hash1,
    ///                     commandBuffer: commandBuffer) { ... }
    /// cache.renderToCache(characterID: "avatar2", poseHash: hash2,
    ///                     commandBuffer: commandBuffer) { ... }
    ///
    /// commandBuffer.commit()  // Submit all renders at once
    /// ```
    ///
    /// - Parameters:
    ///   - characterID: Character identifier for cache management
    ///   - poseHash: Unique pose hash for cache key (use `computePoseHash()`)
    ///   - resolution: Texture resolution (nil = use `defaultResolution` of 512×512)
    ///   - externalCommandBuffer: Optional command buffer to encode into. If `nil`, system creates one.
    ///     When provided, you must call `commit()` yourself. The system will NOT commit it.
    ///   - waitUntilCompleted: If `true` and no `externalCommandBuffer` provided, blocks until GPU finishes.
    ///     Ignored if `externalCommandBuffer` is provided (blocking with external buffers is caller's responsibility).
    ///     Default is `false` (async).
    ///   - completion: Optional callback invoked on `callbackQueue` (default `.main`) when render completes.
    ///     Receives `CachedPose?` - `nil` if caching failed.
    ///   - renderBlock: Closure that performs the actual rendering. Receives encoder and target texture.
    ///     Must be `@Sendable` for thread safety.
    ///
    /// - Returns:
    ///   - **Synchronous path** (`waitUntilCompleted: true`, no external buffer): Returns `CachedPose?` immediately.
    ///   - **Async path** (default): Returns `nil`. Use `completion` handler to receive result.
    ///   - **Already pending**: Returns `nil` if this `poseHash` is already being rendered.
    ///   - **Failure**: Returns `nil` if texture allocation or encoding fails.
    public func renderToCache(
        characterID: String,
        poseHash: UInt64,
        resolution: CGSize? = nil,
        commandBuffer externalCommandBuffer: MTLCommandBuffer? = nil,
        waitUntilCompleted: Bool = false,
        completion: (@Sendable (CachedPose?) -> Void)? = nil,
        renderBlock: @Sendable (MTLRenderCommandEncoder, MTLTexture) -> Void
    ) -> CachedPose? {
        let targetResolution = resolution ?? defaultResolution

        // Atomic check-and-set to prevent duplicate renders
        let (inserted, _) = locked {
            pendingRenders.insert(poseHash)
        }

        if !inserted {
            // Already rendering this pose
            return nil
        }

        // Create texture descriptor for sprite
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(targetResolution.width),
            height: Int(targetResolution.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            cancelPendingRender(for: poseHash)
            return nil
        }

        // Create render pass descriptor
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        // Optional depth buffer for 3D rendering
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: Int(targetResolution.width),
            height: Int(targetResolution.height),
            mipmapped: false
        )
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private

        guard let depthTexture = device.makeTexture(descriptor: depthDescriptor) else {
            cancelPendingRender(for: poseHash)
            return nil
        }

        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1.0
        renderPassDescriptor.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = externalCommandBuffer ?? commandQueue.makeCommandBuffer() else {
            cancelPendingRender(for: poseHash)
            return nil
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            cancelPendingRender(for: poseHash)
            return nil
        }

        encoder.label = "Sprite Cache Render"

        // Execute user's rendering
        renderBlock(encoder, texture)

        encoder.endEncoding()

        let pending = PendingPose(
            texture: texture, poseHash: poseHash, characterID: characterID,
            resolution: targetResolution)
        let shouldSynchronize = waitUntilCompleted && externalCommandBuffer == nil

        if shouldSynchronize {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let cached = finalizePendingPose(pending)
            completion?(cached)
            return cached
        } else {
            commandBuffer.addCompletedHandler { [weak self] buffer in
                guard let self = self else { return }

                // Check for GPU errors before finalizing
                if buffer.status == .error {
                    self.cancelPendingRender(for: pending.poseHash)
                    if let completion = completion {
                        self.callbackQueue.async {
                            completion(nil)
                        }
                    }
                    return
                }

                let cached = self.finalizePendingPose(pending)
                if let completion = completion {
                    self.callbackQueue.async {
                        completion(cached)
                    }
                }
            }
            if externalCommandBuffer == nil {
                commandBuffer.commit()
            }
            return nil
        }
    }

    /// Get cached pose or render and cache if missing (cache-or-render pattern)
    ///
    /// **Breaking Change (PR #38)**: This method now returns `nil` for async renders (cache miss).
    /// Use the `completion` handler to receive the result when rendering completes.
    ///
    /// ## Behavior
    ///
    /// - **Cache hit**: Returns `CachedPose` immediately (no rendering, no async operation)
    /// - **Cache miss (sync)**: With `waitForCompletion: true`, blocks until render completes, returns `CachedPose?`
    /// - **Cache miss (async)**: Returns `nil` immediately, invokes `completion` when ready (recommended)
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Attempt cache lookup with async fallback
    /// if let cached = cache.getOrRender(
    ///     characterID: "avatar1",
    ///     poseHash: hash,
    ///     completion: { pose in
    ///         // Only called on cache miss after render completes
    ///         guard let pose = pose else { return }
    ///         // Use freshly rendered pose
    ///     }
    /// ) { encoder, texture in
    ///     // Only called on cache miss
    ///     renderCharacter(encoder: encoder, texture: texture)
    /// } {
    ///     // Cache hit - use cached pose immediately
    ///     useCachedPose(cached)
    /// } else {
    ///     // Cache miss - rendering in progress, wait for completion callback
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - characterID: Character identifier for cache management
    ///   - poseHash: Pose hash (use `computePoseHash()`)
    ///   - resolution: Target resolution (nil = 512×512 default)
    ///   - commandBuffer: Optional command buffer for batching (nil = system creates one)
    ///   - waitForCompletion: If `true` with no external buffer, blocks on cache miss. Default `false`.
    ///   - completion: Callback invoked on cache miss after render completes (runs on `callbackQueue`)
    ///   - renderBlock: Rendering closure, called only on cache miss
    ///
    /// - Returns:
    ///   - **Cache hit**: `CachedPose` (ready to use immediately)
    ///   - **Cache miss (async)**: `nil` (use `completion` handler)
    ///   - **Cache miss (sync)**: `CachedPose?` after blocking render
    ///   - **Already rendering**: `nil`
    public func getOrRender(
        characterID: String,
        poseHash: UInt64,
        resolution: CGSize? = nil,
        commandBuffer: MTLCommandBuffer? = nil,
        waitForCompletion: Bool = false,
        completion: (@Sendable (CachedPose?) -> Void)? = nil,
        renderBlock: @Sendable (MTLRenderCommandEncoder, MTLTexture) -> Void
    ) -> CachedPose? {
        // Check cache first
        if let cached = getCachedPose(poseHash: poseHash) {
            return cached
        }

        // Cache miss - render and cache
        return renderToCache(
            characterID: characterID,
            poseHash: poseHash,
            resolution: resolution,
            commandBuffer: commandBuffer,
            waitUntilCompleted: waitForCompletion,
            completion: completion,
            renderBlock: renderBlock
        )
    }
}

// MARK: - Sprite Rendering Helper

extension SpriteCacheSystem {

    /// Render a sprite quad to the screen
    /// - Parameters:
    ///   - encoder: Render command encoder
    ///   - texture: Sprite texture
    ///   - position: Screen position (center)
    ///   - scale: Sprite scale
    ///   - pipelineState: Pipeline state for sprite rendering
    public func renderSprite(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        position: SIMD2<Float>,
        scale: Float,
        pipelineState: MTLRenderPipelineState
    ) {
        // Note: This is a simplified API
        // In production, you'd use a sprite batch renderer with instancing

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(texture, index: 0)

        // TODO: Bind sprite quad vertex buffer and uniforms
        // This requires a sprite shader and quad mesh
    }
}
