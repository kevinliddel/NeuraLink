//
//  VRMRenderingHelpers.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import MetalKit
import simd

// MARK: - Projection Matrix Helpers

func makePerspective(fovyRadians: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> float4x4
{
    let ys = 1 / tanf(fovyRadians * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)

    return float4x4(
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, nearZ * zs, 0)
    )
}

// MARK: - Dummy View for Headless Rendering

class DummyView: MTKView {
    private let _size: CGSize

    init(size: CGSize) {
        self._size = size
        super.init(frame: .zero, device: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var drawableSize: CGSize {
        get { _size }
        set {}  // Ignore sets
    }
}

// MARK: - Matrix Extensions

extension float4x4 {
    var inverse: float4x4 {
        return simd_inverse(self)
    }

    var transpose: float4x4 {
        return simd_transpose(self)
    }
}

// MARK: - Vector Extensions

extension SIMD3<Float> {
    var normalized: SIMD3<Float> {
        let length = sqrt(x * x + y * y + z * z)
        guard length > 0 else { return self }
        return self / length
    }
}
