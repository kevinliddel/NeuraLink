//
//  VRMPipelineCache.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import QuartzCore

/// Global pipeline state cache to avoid recompiling shaders and recreating pipeline states
/// Shared across all VRMRenderer instances for optimal performance
public final class VRMPipelineCache: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = VRMPipelineCache()

    private let lock = NSLock()
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelineStates: [String: MTLRenderPipelineState] = [:]

    private init() {
        lock.name = "com.arkavo.NeuraLink.PipelineCache"
    }

    /// Load or retrieve cached shader library
    public func getLibrary(device: MTLDevice) throws -> MTLLibrary {
        return try lock.withLock {
            let key = "NeuraLinkShaders"

            // Return cached library if available
            if let cached = libraries[key] {
                vrmLog("[VRMPipelineCache] ✅ Using cached shader library")
                return cached
            }

            // Try loading from default library first (standard for Xcode app targets)
            if let defaultLibrary = device.makeDefaultLibrary() {
                libraries[key] = defaultLibrary
                return defaultLibrary
            }

            // Fallback: look for packaged metallib if needed
            if let url = Bundle.main.url(
                forResource: "NeuraLinkShaders", withExtension: "metallib") {
                do {
                    let library = try device.makeLibrary(URL: url)
                    libraries[key] = library
                    return library
                } catch {
                    vrmLog(
                        "[VRMPipelineCache] ❌ Failed to load NeuraLinkShaders.metallib: \(error)")
                }
            }

            vrmLog("[VRMPipelineCache] ❌ Shader library not found and default library unavailable")
            throw PipelineCacheError.shaderLibraryNotFound
        }
    }

    /// Get or create cached pipeline state
    public func getPipelineState(
        device: MTLDevice,
        descriptor: MTLRenderPipelineDescriptor,
        key: String
    ) throws -> MTLRenderPipelineState {
        return try lock.withLock {
            // Return cached pipeline state if available
            if let cached = pipelineStates[key] {
                vrmLog("[VRMPipelineCache] ✅ Using cached pipeline state: \(key)")
                return cached
            }

            // Create new pipeline state
            vrmLog("[VRMPipelineCache] 🔨 Creating new pipeline state: \(key)")
            let startTime = CACurrentMediaTime()

            let state = try device.makeRenderPipelineState(descriptor: descriptor)

            let elapsed = (CACurrentMediaTime() - startTime) * 1000
            vrmLog(
                "[VRMPipelineCache] ✅ Pipeline state created in \(String(format: "%.2f", elapsed))ms"
            )

            pipelineStates[key] = state
            return state
        }
    }

    /// Clear all cached libraries and pipeline states
    ///
    /// This is useful for:
    /// - Testing (reset state between tests)
    /// - Memory pressure (free cached resources)
    /// - Development (force reload of shaders)
    public func clearCache() {
        lock.withLock {
            let libraryCount = libraries.count
            let pipelineCount = pipelineStates.count

            libraries.removeAll()
            pipelineStates.removeAll()

            vrmLog(
                "[VRMPipelineCache] 🗑️ Cache cleared: \(libraryCount) libraries, \(pipelineCount) pipeline states"
            )
        }
    }

    /// Get cache statistics for monitoring
    public func getStatistics() -> CacheStatistics {
        return lock.withLock {
            CacheStatistics(
                libraryCount: libraries.count,
                pipelineStateCount: pipelineStates.count
            )
        }
    }

    /// Cache statistics snapshot
    public struct CacheStatistics {
        public let libraryCount: Int
        public let pipelineStateCount: Int
    }
}

// MARK: - Error Types

public enum PipelineCacheError: Error, LocalizedError {
    case shaderLibraryNotFound
    case shaderLibraryLoadFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .shaderLibraryNotFound:
            return "NeuraLinkShaders.metallib not found in package resources"
        case .shaderLibraryLoadFailed(let error):
            return "Failed to load NeuraLinkShaders.metallib: \(error.localizedDescription)"
        }
    }
}
