//
// VRMSkinning.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Metal
import simd

// MARK: - Skinning System

public class VRMSkinningSystem {
    private let device: MTLDevice
    public var jointMatricesBuffer: MTLBuffer?
    private var totalMatrixCount = 0

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Allocates a single GPU buffer large enough for all skins and assigns byte offsets.
    /// Must be called once after model load before any `updateJointMatrices` calls.
    public func setupForSkins(_ skins: [VRMSkin]) {
        var currentOffset = 0
        var currentByteOffset = 0
        let matrixSize = MemoryLayout<float4x4>.stride

        for skin in skins {
            skin.matrixOffset = currentOffset
            skin.bufferByteOffset = currentByteOffset
            currentOffset += skin.joints.count
            currentByteOffset += skin.joints.count * matrixSize
        }

        totalMatrixCount = currentOffset

        // Pad to at least 256 matrices so shader clamp-to-255 index is always safe.
        let paddedCount = max(totalMatrixCount, 256)
        jointMatricesBuffer = device.makeBuffer(
            length: paddedCount * matrixSize, options: .storageModeShared)

        // Pre-fill with identity so out-of-range reads are benign.
        if let buffer = jointMatricesBuffer {
            let ptr = buffer.contents().bindMemory(to: float4x4.self, capacity: paddedCount)
            for i in 0..<paddedCount { ptr[i] = float4x4(1) }
        }
    }

    /// Computes `worldMatrix * inverseBindMatrix` for every joint in `skin` and writes
    /// the palette into the shared GPU buffer at the skin's pre-assigned byte offset.
    public func updateJointMatrices(for skin: VRMSkin, skinIndex: Int) {
        guard let buffer = jointMatricesBuffer else { return }

        var matrices = [float4x4]()
        matrices.reserveCapacity(skin.joints.count)

        for (index, joint) in skin.joints.enumerated() {
            let skinMatrix = joint.worldMatrix * skin.inverseBindMatrices[index]
            // NaN/Inf guard: corrupted inputs fall back to identity to prevent GPU artifacts.
            let isValid =
                skinMatrix[0][0].isFinite && skinMatrix[1][1].isFinite
                && skinMatrix[2][2].isFinite && skinMatrix[3][3].isFinite
            matrices.append(isValid ? skinMatrix : float4x4(1))
        }

        let ptr = buffer.contents().advanced(by: skin.bufferByteOffset)
            .bindMemory(to: float4x4.self, capacity: skin.joints.count)
        for (i, matrix) in matrices.enumerated() { ptr[i] = matrix }
    }

    /// Called at the start of each frame to reset per-frame caches.
    public func beginFrame() {}

    public func getJointMatricesBuffer() -> MTLBuffer? { jointMatricesBuffer }
    public func getBufferOffset(for skin: VRMSkin) -> Int { skin.bufferByteOffset }
    public func getTotalMatrixCount() -> Int { totalMatrixCount }
}

// MARK: - Animation State

/// Lightweight per-frame bone state used by VRMLookAtController in bone mode.
public class VRMAnimationState {
    public var time: Float = 0
    public var bones: [VRMHumanoidBone: BoneTransform] = [:]

    public struct BoneTransform {
        public var rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        public var translation: SIMD3<Float> = [0, 0, 0]
        public var scale: SIMD3<Float> = [1, 1, 1]
        public init() {}
    }

    public init() {}

    public func resetToTPose() { bones.removeAll() }

    public func applyToModel(_ model: VRMModel) {
        guard let humanoid = model.humanoid else { return }

        for (bone, transform) in bones {
            guard let nodeIndex = humanoid.getBoneNode(bone),
                nodeIndex < model.nodes.count
            else { continue }

            let node = model.nodes[nodeIndex]
            node.rotation = transform.rotation
            node.translation = transform.translation
            node.scale = transform.scale
            node.updateLocalMatrix()
        }

        for node in model.nodes where node.parent == nil {
            node.updateWorldTransform()
        }
    }
}
