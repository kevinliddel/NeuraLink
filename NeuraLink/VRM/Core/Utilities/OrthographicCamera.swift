//
// OrthographicCamera.swift
// NeuraLink
//
// Created by Dedicatus on 16/04/2026.
//

import Foundation
import simd

/// Orthographic camera utilities for 2.5D VRM rendering
/// Provides projection matrices optimized for visual novel/dialogue scenes
public struct OrthographicCamera {

    // MARK: - Camera Presets

    /// Standard camera framing presets for VRM characters
    public enum Preset {
        case bust  // Tight VTuber-style framing (shoulders and up)
        case medium  // Upper body framing (waist and up)
        case fullBody  // Full character visible
        case custom(height: Float)  // Custom height in world units

        /// Height in world units (assuming standard 1.6-1.8m VRM)
        public var height: Float {
            switch self {
            case .bust:
                return 0.6  // ~30% of character height
            case .medium:
                return 1.2  // ~70% of character height
            case .fullBody:
                return 2.0  // 110% of character height (with headroom)
            case .custom(let h):
                return h
            }
        }

        /// Descriptive name for debugging
        public var name: String {
            switch self {
            case .bust: return "Bust"
            case .medium: return "Medium"
            case .fullBody: return "Full Body"
            case .custom(let h): return "Custom(\(h)m)"
            }
        }
    }

    // MARK: - Projection Matrix Construction

    /// Create orthographic projection matrix from preset
    /// - Parameters:
    ///   - preset: Camera framing preset
    ///   - aspectRatio: Viewport width / height
    ///   - near: Near clipping plane (default: 0.1)
    ///   - far: Far clipping plane (default: 100.0)
    /// - Returns: Orthographic projection matrix
    public static func makeProjection(
        preset: Preset,
        aspectRatio: Float,
        near: Float = 0.1,
        far: Float = 100.0
    ) -> simd_float4x4 {
        return makeProjection(
            height: preset.height,
            aspectRatio: aspectRatio,
            near: near,
            far: far
        )
    }

    /// Create orthographic projection matrix with explicit height
    /// - Parameters:
    ///   - height: Height of the view frustum in world units
    ///   - aspectRatio: Viewport width / height
    ///   - near: Near clipping plane
    ///   - far: Far clipping plane
    /// - Returns: Orthographic projection matrix
    public static func makeProjection(
        height: Float,
        aspectRatio: Float,
        near: Float = 0.1,
        far: Float = 100.0
    ) -> simd_float4x4 {
        let halfHeight = height / 2.0
        let halfWidth = halfHeight * aspectRatio

        return makeOrthographic(
            left: -halfWidth,
            right: halfWidth,
            bottom: -halfHeight,
            top: halfHeight,
            near: near,
            far: far
        )
    }

    /// Create orthographic projection matrix from explicit bounds
    /// - Parameters:
    ///   - left: Left clipping plane
    ///   - right: Right clipping plane
    ///   - bottom: Bottom clipping plane
    ///   - top: Top clipping plane
    ///   - near: Near clipping plane
    ///   - far: Far clipping plane
    /// - Returns: Orthographic projection matrix
    public static func makeOrthographic(
        left: Float,
        right: Float,
        bottom: Float,
        top: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let rml = right - left
        let tmb = top - bottom
        let fmn = far - near

        // OpenGL-style orthographic projection (Metal uses same convention)
        return simd_float4x4(
            columns: (
                SIMD4<Float>(2.0 / rml, 0, 0, 0),
                SIMD4<Float>(0, 2.0 / tmb, 0, 0),
                SIMD4<Float>(0, 0, -1.0 / fmn, 0),
                SIMD4<Float>(-(right + left) / rml, -(top + bottom) / tmb, -near / fmn, 1)
            ))
    }

    // MARK: - View Matrix Construction

    /// Create view matrix for orthographic 2.5D rendering
    /// Positions camera to center character in frame
    /// - Parameters:
    ///   - characterPosition: World position of character center (usually origin)
    ///   - distance: Distance from character (default: 5.0 units)
    ///   - offset: Optional vertical offset for centering (default: 0)
    /// - Returns: View matrix looking at character
    public static func makeViewMatrix(
        characterPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        distance: Float = 5.0,
        offset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    ) -> simd_float4x4 {
        // Camera position: in front of character along +Z axis
        let cameraPosition = characterPosition + SIMD3<Float>(0, 0, distance) + offset

        // Look at character
        let target = characterPosition
        let up = SIMD3<Float>(0, 1, 0)  // Y-up

        return makeLookAt(eye: cameraPosition, target: target, up: up)
    }

    /// Create look-at view matrix
    /// - Parameters:
    ///   - eye: Camera position
    ///   - target: Point camera is looking at
    ///   - up: Up vector (usually (0, 1, 0))
    /// - Returns: View matrix
    public static func makeLookAt(
        eye: SIMD3<Float>,
        target: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> simd_float4x4 {
        // Calculate basis vectors
        let zAxis = normalize(eye - target)  // Forward (camera looks along -Z)
        let xAxis = normalize(cross(up, zAxis))  // Right
        let yAxis = cross(zAxis, xAxis)  // Up

        // Build view matrix
        return simd_float4x4(
            columns: (
                SIMD4<Float>(xAxis.x, yAxis.x, zAxis.x, 0),
                SIMD4<Float>(xAxis.y, yAxis.y, zAxis.y, 0),
                SIMD4<Float>(xAxis.z, yAxis.z, zAxis.z, 0),
                SIMD4<Float>(-dot(xAxis, eye), -dot(yAxis, eye), -dot(zAxis, eye), 1)
            ))
    }

    // MARK: - Camera Configuration

    /// Complete camera configuration for 2.5D rendering
    public struct Configuration {
        public var preset: Preset
        public var aspectRatio: Float
        public var nearPlane: Float
        public var farPlane: Float
        public var characterPosition: SIMD3<Float>
        public var cameraDistance: Float
        public var offset: SIMD3<Float>

        public init(
            preset: Preset = .medium,
            aspectRatio: Float = 16.0 / 9.0,
            nearPlane: Float = 0.1,
            farPlane: Float = 100.0,
            characterPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
            cameraDistance: Float = 5.0,
            offset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
        ) {
            self.preset = preset
            self.aspectRatio = aspectRatio
            self.nearPlane = nearPlane
            self.farPlane = farPlane
            self.characterPosition = characterPosition
            self.cameraDistance = cameraDistance
            self.offset = offset
        }

        /// Generate projection matrix from configuration
        public var projectionMatrix: simd_float4x4 {
            return OrthographicCamera.makeProjection(
                preset: preset,
                aspectRatio: aspectRatio,
                near: nearPlane,
                far: farPlane
            )
        }

        /// Generate view matrix from configuration
        public var viewMatrix: simd_float4x4 {
            return OrthographicCamera.makeViewMatrix(
                characterPosition: characterPosition,
                distance: cameraDistance,
                offset: offset
            )
        }
    }

    // MARK: - Utility Functions

    /// Calculate appropriate camera distance for a given character height
    /// Ensures character fits within viewport with some padding
    /// - Parameters:
    ///   - characterHeight: Height of character in world units
    ///   - preset: Camera framing preset
    ///   - padding: Extra space factor (1.0 = no padding, 1.2 = 20% padding)
    /// - Returns: Recommended camera distance
    public static func calculateDistance(
        forCharacterHeight characterHeight: Float,
        preset: Preset,
        padding: Float = 1.1
    ) -> Float {
        // For orthographic, distance doesn't affect size, but we want
        // reasonable Z-buffer precision. Place camera far enough to
        // see full character depth (assuming ~0.5m character depth)
        let characterDepth: Float = 0.5
        let minDistance = characterDepth * 2.0  // At least 2x character depth

        // Add some extra distance for comfort
        return max(minDistance, 5.0) * padding
    }

    /// Convert screen coordinates to world coordinates for orthographic camera
    /// Useful for mouse picking, UI interaction with characters
    /// - Parameters:
    ///   - screenPoint: Point in screen space (0,0 = top-left, viewport size = bottom-right)
    ///   - viewportSize: Size of viewport in pixels
    ///   - viewMatrix: Current view matrix
    ///   - projectionMatrix: Current projection matrix
    ///   - depth: Z-depth in NDC space (-1 to 1, default 0 = character plane)
    /// - Returns: World space position
    public static func screenToWorld(
        screenPoint: SIMD2<Float>,
        viewportSize: SIMD2<Float>,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        depth: Float = 0.0
    ) -> SIMD3<Float> {
        // Convert screen to NDC
        let ndcX = (2.0 * screenPoint.x) / viewportSize.x - 1.0
        let ndcY = 1.0 - (2.0 * screenPoint.y) / viewportSize.y  // Flip Y
        let ndc = SIMD4<Float>(ndcX, ndcY, depth, 1.0)

        // Inverse projection and view
        let inverseProjection = projectionMatrix.inverse
        let inverseView = viewMatrix.inverse

        // To view space
        let viewPos = inverseProjection * ndc

        // To world space
        let worldPos = inverseView * viewPos

        return SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)
    }
}
