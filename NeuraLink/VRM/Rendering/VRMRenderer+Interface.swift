//
//  VRMRenderer+API.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Metal
import MetalKit
import simd

// MARK: - Projection

extension VRMRenderer {

    /// Model rotation correction for VRM coordinate system differences.
    var vrmVersionRotation: matrix_float4x4 {
        guard let model = model else { return matrix_identity_float4x4 }
        if model.isVRM0 {
            return matrix_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        } else {
            return matrix_identity_float4x4
        }
    }

    public func makeProjectionMatrix(aspectRatio: Float) -> matrix_float4x4 {
        guard aspectRatio > 0 && aspectRatio.isFinite else {
            return makeProjectionMatrix(aspectRatio: 1.0)
        }

        if useOrthographic {
            let halfHeight = orthoSize / 2.0
            let halfWidth = halfHeight * aspectRatio
            let width = halfWidth * 2.0
            let height = halfHeight * 2.0
            let nearZ: Float = 0.1
            let farZ: Float = 100.0
            let depth = farZ - nearZ
            return matrix_float4x4(
                columns: (
                    SIMD4<Float>(2.0 / width, 0, 0, 0),
                    SIMD4<Float>(0, 2.0 / height, 0, 0),
                    SIMD4<Float>(0, 0, -1.0 / depth, 0),
                    SIMD4<Float>(0, 0, farZ / depth, 1)
                ))
        } else {
            let fovy = fovDegrees * Float.pi / 180.0
            let ys = 1.0 / tan(fovy * 0.5)
            let xs = ys / aspectRatio
            let nearZ: Float = 0.1
            let farZ: Float = 100.0
            let zs = farZ / (nearZ - farZ)
            return matrix_float4x4(
                columns: (
                    SIMD4<Float>(xs, 0, 0, 0),
                    SIMD4<Float>(0, ys, 0, 0),
                    SIMD4<Float>(0, 0, zs, -1),
                    SIMD4<Float>(0, 0, zs * nearZ, 0)
                ))
        }
    }
}

// MARK: - Lighting API

extension VRMRenderer {

    public func setLight(
        _ index: Int,
        direction: SIMD3<Float>,
        color: SIMD3<Float>,
        intensity: Float = 1.0
    ) {
        var normalizedDir = direction
        let length = simd_length(direction)
        if length < 0.0001 {
            normalizedDir = SIMD3<Float>(0, 1, 0)
        } else {
            normalizedDir = simd_normalize(direction)
        }

        let finalColor = color * intensity

        switch index {
        case 0:
            storedLightDirections.0 = normalizedDir
            uniforms.lightDirection = normalizedDir
            uniforms.lightColor = finalColor
        case 1:
            storedLightDirections.1 = normalizedDir
            uniforms.light1Direction = normalizedDir
            uniforms.light1Color = finalColor
        case 2:
            storedLightDirections.2 = normalizedDir
            uniforms.light2Direction = normalizedDir
            uniforms.light2Color = finalColor
        default:
            break
        }
    }

    public func disableLight(_ index: Int) {
        setLight(index, direction: SIMD3<Float>(0, 1, 0), color: SIMD3<Float>(0, 0, 0))
    }

    public func setup3PointLighting(
        keyIntensity: Float = 1.0,
        fillIntensity: Float = 0.5,
        rimIntensity: Float = 0.3
    ) {
        setLight(
            0,
            direction: SIMD3<Float>(0.3, -0.2, -0.9),
            color: SIMD3<Float>(1.0, 0.98, 0.95),
            intensity: keyIntensity)
        setLight(
            1,
            direction: SIMD3<Float>(-0.4, -0.1, -0.9),
            color: SIMD3<Float>(0.85, 0.88, 0.95),
            intensity: fillIntensity)
        setLight(
            2,
            direction: SIMD3<Float>(0.0, -0.5, 0.85),
            color: SIMD3<Float>(0.9, 0.95, 1.0),
            intensity: rimIntensity)
    }

    public func setAmbientColor(_ color: SIMD3<Float>) {
        uniforms.ambientColor = simd_clamp(
            color,
            SIMD3<Float>(repeating: 0.0),
            SIMD3<Float>(repeating: 1.0)
        )
    }

    public func setLightNormalizationMode(_ mode: LightNormalizationMode) {
        lightNormalizationMode = mode
    }
}

// MARK: - Spring Bone Physics API

extension VRMRenderer {

    public func resetPhysics() {
        springBoneComputeSystem?.requestPhysicsReset = true
    }

    public func setColliderRadius(at index: Int, radius: Float) {
        springBoneComputeSystem?.setSphereColliderRadius(index: index, radius: radius)
    }

    public func clearColliderRadiusOverride(at index: Int) {
        springBoneComputeSystem?.clearSphereColliderRadiusOverride(index: index)
    }

    public func clearAllColliderRadiusOverrides() {
        springBoneComputeSystem?.clearAllColliderRadiusOverrides()
    }

    public func warmupPhysics(steps: Int = 30) {
        guard let model = model else { return }
        springBoneComputeSystem?.warmupPhysics(model: model, steps: steps)
    }
}

// MARK: - Draw Entry Points

extension VRMRenderer {

    @MainActor
    public func drawOffscreenHeadless(
        to colorTexture: MTLTexture,
        depth: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        let dummyView = DummyView(
            size: CGSize(width: colorTexture.width, height: colorTexture.height))
        drawCore(
            in: dummyView, commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
    }

    @MainActor
    public func draw(
        in view: MTKView,
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        drawCore(in: view, commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
    }
}
