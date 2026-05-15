//
// VRMConstants.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

/// Centralized constants for NeuraLink configuration and default values.
/// This provides a single source of truth for magic numbers used throughout the codebase.
public enum VRMConstants {

    // MARK: - Rendering

    public enum Rendering {
        /// Number of frames to triple-buffer uniforms to avoid CPU-GPU sync stalls
        public static let maxBufferedFrames: Int = 3

        /// Default field of view in radians (60 degrees)
        public static let defaultFOV: Float = .pi / 3.0

        /// Default near clipping plane distance
        public static let defaultNearPlane: Float = 0.1

        /// Default far clipping plane distance
        public static let defaultFarPlane: Float = 100.0

        /// Maximum number of active morph targets that can be processed simultaneously
        public static let maxActiveMorphs: Int = 8

        /// Maximum total morph targets supported per mesh
        public static let maxMorphTargets: Int = 64

        /// Threshold for switching from CPU to GPU morph computation
        public static let morphComputeThreshold: Int = 8
    }

    // MARK: - Physics

    /// Quality levels for spring bone physics simulation
    public enum SpringBoneQuality: Int, Sendable {
        case ultra = 0  // 120Hz, 4 iterations - highest quality
        case high = 1  // 90Hz, 3 iterations
        case medium = 2  // 60Hz, 2 iterations
        case low = 3  // 30Hz, 1 iteration - battery saver
        case off = 4  // Physics disabled

        /// Substep rate in Hz for this quality level
        public var substepRateHz: Double {
            switch self {
            case .ultra: return 120.0
            case .high: return 90.0
            case .medium: return 60.0
            case .low: return 30.0
            case .off: return 0.0
            }
        }

        /// Number of constraint iterations per substep
        public var constraintIterations: Int {
            switch self {
            case .ultra: return 4
            case .high: return 3
            case .medium: return 2
            case .low: return 1
            case .off: return 0
            }
        }

        /// Maximum substeps per frame
        public var maxSubstepsPerFrame: Int {
            switch self {
            case .ultra: return 10
            case .high: return 8
            case .medium: return 6
            case .low: return 4
            case .off: return 0
            }
        }
    }

    public enum Physics {
        /// SpringBone simulation substep rate in Hz for stable physics
        public static let substepRateHz: Double = 120.0

        /// Maximum number of substeps to process per frame to avoid spiral of death
        public static let maxSubstepsPerFrame: Int = 10

        /// Number of XPBD constraint iterations per substep
        public static let constraintIterations: Int = 4

        /// Default gravity vector in world space (m/s²)
        public static let defaultGravity = SIMD3<Float>(0, -9.8, 0)

        /// Epsilon for morph target weight comparison (weights below this are considered zero)
        public static let morphEpsilon: Float = 1e-4

        /// Enable linear interpolation of root positions across substeps
        /// When true, root bone positions are smoothly interpolated from previous frame to current,
        /// preventing "velocity sledgehammer" that causes hair/cloth explosion
        public static let enableRootInterpolation: Bool = true

        /// Minimum model scale for threshold calculation
        /// Prevents division issues and ensures very small models still have reasonable teleportation detection
        public static let minScaleForThreshold: Float = 0.1
    }

    // MARK: - Animation

    public enum Animation {
        /// Maximum number of joints supported for skeletal animation
        public static let maxJointCount: Int = 256

        /// Default animation playback speed multiplier
        public static let defaultPlaybackSpeed: Float = 1.0
    }

    // MARK: - Buffer Limits

    public enum BufferLimits {
        /// Maximum texture size in pixels
        public static let maxTextureSize: Int = 8192

        /// Preferred texture size for performance
        public static let preferredTextureSize: Int = 2048

        /// Maximum number of draw calls per frame before performance warning
        public static let maxDrawCallsWarningThreshold: Int = 1000
    }

    // MARK: - Performance

    public enum Performance {
        /// Frequency for periodic status logging (every N frames)
        public static let statusLogInterval: Int = 120

        /// Command buffer timeout in milliseconds
        public static let commandBufferTimeout: Int = 120000  // 2 minutes
    }

    // MARK: - Debug

    public enum Debug {
        /// Number of initial frames to log for debugging
        public static let initialFrameLogCount: Int = 3

        /// Interval for periodic logging (every N frames)
        public static let periodicLogInterval: Int = 60
    }
}
