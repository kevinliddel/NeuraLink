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

    public enum Physics {
        /// Epsilon for morph target weight comparison (weights below this are considered zero)
        public static let morphEpsilon: Float = 1e-4
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
