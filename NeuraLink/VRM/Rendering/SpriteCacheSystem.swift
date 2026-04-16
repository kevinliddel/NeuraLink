//
//  SpriteCacheSystem.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import CoreGraphics
import Foundation
import Metal
import simd

/// Sprite cache system for optimizing multi-character 2.5D rendering
/// Caches pre-rendered character poses as textures to achieve 60 FPS with 5+ characters
public class SpriteCacheSystem: @unchecked Sendable {

    // MARK: - Cache Entry

    /// A cached sprite representing a specific character pose
    public struct CachedPose: @unchecked Sendable {
        /// Rendered sprite texture (RGBA8 or BGRA8)
        public let texture: MTLTexture

        /// Deterministic hash of the pose state
        public let poseHash: UInt64

        /// Timestamp for LRU eviction
        public var timestamp: TimeInterval

        /// Texture resolution
        public let resolution: CGSize

        /// Character identifier (for multi-character scenes)
        public let characterID: String

        /// Memory footprint in bytes
        public var memoryBytes: Int {
            let bytesPerPixel = 4  // RGBA8
            return Int(resolution.width * resolution.height) * bytesPerPixel
        }

        public init(
            texture: MTLTexture,
            poseHash: UInt64,
            timestamp: TimeInterval,
            resolution: CGSize,
            characterID: String
        ) {
            self.texture = texture
            self.poseHash = poseHash
            self.timestamp = timestamp
            self.resolution = resolution
            self.characterID = characterID
        }
    }

    // MARK: - Internal Pending Pose

    struct PendingPose: @unchecked Sendable {
        let texture: MTLTexture
        let poseHash: UInt64
        let characterID: String
        let resolution: CGSize
    }

    // MARK: - Configuration

    /// Maximum number of cached poses
    public var maxCacheSize: Int = 100

    /// Maximum memory usage in bytes (default: 256MB)
    public var maxMemoryBytes: Int = 256 * 1024 * 1024

    /// Default sprite resolution
    public var defaultResolution: CGSize = CGSize(width: 512, height: 512)

    /// Quantization precision for pose hashing
    public var expressionQuantization: Float = 0.01  // 1% precision
    public var rotationQuantization: Float = 5.0  // 5° buckets

    // MARK: - Cache State

    var cache: [UInt64: CachedPose] = [:]
    var pendingRenders: Set<UInt64> = []
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let callbackQueue: DispatchQueue
    private let cacheLock = NSLock()

    // Statistics
    var cacheHits: Int = 0
    var cacheMisses: Int = 0

    // MARK: - Initialization

    public init(
        device: MTLDevice, commandQueue: MTLCommandQueue, callbackQueue: DispatchQueue = .main
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.callbackQueue = callbackQueue
    }

    // MARK: - Lock Helper

    @discardableResult
    func locked<T>(_ body: () -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body()
    }

    func cancelPendingRender(for poseHash: UInt64) {
        locked {
            pendingRenders.remove(poseHash)
        }
    }

    // MARK: - Pose Hashing

    /// Compute deterministic hash for a character pose
    public func computePoseHash(
        characterID: String,
        expressionWeights: [String: Float],
        animationFrame: Int? = nil,
        headRotation: SIMD3<Float>? = nil,
        bodyRotation: SIMD3<Float>? = nil
    ) -> UInt64 {
        var hasher = Hasher()

        // Character ID
        hasher.combine(characterID)

        // Expression weights (sorted for determinism)
        for (name, weight) in expressionWeights.sorted(by: { $0.key < $1.key }) {
            hasher.combine(name)
            // Quantize to expressionQuantization (default 0.01)
            let quantized = Int(weight / expressionQuantization)
            hasher.combine(quantized)
        }

        // Animation frame
        if let frame = animationFrame {
            hasher.combine(frame)
        }

        // Head rotation (quantized to rotationQuantization buckets)
        if let rotation = headRotation {
            let qx = Int(rotation.x * 180 / .pi / rotationQuantization)
            let qy = Int(rotation.y * 180 / .pi / rotationQuantization)
            let qz = Int(rotation.z * 180 / .pi / rotationQuantization)
            hasher.combine(qx)
            hasher.combine(qy)
            hasher.combine(qz)
        }

        // Body rotation
        if let rotation = bodyRotation {
            let qx = Int(rotation.x * 180 / .pi / rotationQuantization)
            let qy = Int(rotation.y * 180 / .pi / rotationQuantization)
            let qz = Int(rotation.z * 180 / .pi / rotationQuantization)
            hasher.combine(qx)
            hasher.combine(qy)
            hasher.combine(qz)
        }

        return UInt64(hasher.finalize())
    }

    // MARK: - Cache Lookup

    /// Check if a pose is cached
    public func isCached(poseHash: UInt64) -> Bool {
        return locked {
            cache[poseHash] != nil
        }
    }

    /// Retrieve cached pose if available
    public func getCachedPose(poseHash: UInt64) -> CachedPose? {
        return locked {
            if var pose = cache[poseHash] {
                pose.timestamp = Date().timeIntervalSince1970
                cache[poseHash] = pose
                cacheHits += 1
                return pose
            } else {
                cacheMisses += 1
                return nil
            }
        }
    }

    // MARK: - Cache Storage

    @discardableResult
    func storePoseLocked(_ pose: CachedPose) -> Bool {
        while shouldEvictLocked(additionalBytes: pose.memoryBytes) {
            evictLRULocked()
        }
        cache[pose.poseHash] = pose
        pendingRenders.remove(pose.poseHash)
        return true
    }

    func finalizePendingPose(_ pending: PendingPose) -> CachedPose? {
        let pose = CachedPose(
            texture: pending.texture,
            poseHash: pending.poseHash,
            timestamp: Date().timeIntervalSince1970,
            resolution: pending.resolution,
            characterID: pending.characterID
        )

        return locked {
            _ = storePoseLocked(pose)
            return cache[pose.poseHash]
        }
    }

    /// Add a rendered pose to the cache
    @discardableResult
    public func cachePose(
        texture: MTLTexture,
        poseHash: UInt64,
        characterID: String
    ) -> Bool {
        let resolution = CGSize(
            width: texture.width,
            height: texture.height
        )

        let pose = CachedPose(
            texture: texture,
            poseHash: poseHash,
            timestamp: Date().timeIntervalSince1970,
            resolution: resolution,
            characterID: characterID
        )

        return locked {
            storePoseLocked(pose)
        }
    }

    // MARK: - Cache Management

    /// Check if we should evict entries to make room
    private func shouldEvictLocked(additionalBytes: Int) -> Bool {
        let currentMemory = cache.values.reduce(0) { $0 + $1.memoryBytes }

        // Evict if over memory limit or cache size limit
        return (currentMemory + additionalBytes > maxMemoryBytes) || (cache.count >= maxCacheSize)
    }

    /// Evict least recently used entry
    private func evictLRULocked() {
        guard let lruEntry = cache.values.min(by: { $0.timestamp < $1.timestamp }) else {
            return
        }

        cache.removeValue(forKey: lruEntry.poseHash)
    }

    /// Clear entire cache
    public func clearCache() {
        locked {
            cache.removeAll()
            pendingRenders.removeAll()
            cacheHits = 0
            cacheMisses = 0
        }
    }

    /// Clear cache entries for a specific character
    public func clearCharacter(_ characterID: String) {
        locked {
            let removed = cache.filter { $0.value.characterID == characterID }
            for (hash, _) in removed {
                cache.removeValue(forKey: hash)
                pendingRenders.remove(hash)
            }
        }
    }

    // MARK: - Statistics

    /// Get cache statistics
    public func getStatistics() -> CacheStatistics {
        return locked {
            let totalMemory = cache.values.reduce(0) { $0 + $1.memoryBytes }
            let hitRate =
                cacheHits + cacheMisses > 0
                ? Float(cacheHits) / Float(cacheHits + cacheMisses)
                : 0.0

            return CacheStatistics(
                entryCount: cache.count,
                totalMemoryBytes: totalMemory,
                maxMemoryBytes: maxMemoryBytes,
                cacheHits: cacheHits,
                cacheMisses: cacheMisses,
                hitRate: hitRate,
                pendingRenders: pendingRenders.count
            )
        }
    }

    /// Reset statistics counters
    public func resetStatistics() {
        locked {
            cacheHits = 0
            cacheMisses = 0
        }
    }
}
