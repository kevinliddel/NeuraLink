//
//  VRMUniformBufferRing.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal

/// Manages the triple-buffered uniform ring and CPU/GPU synchronization.
final class VRMUniformBufferRing {
    private let semaphore: DispatchSemaphore
    private let buffers: [MTLBuffer]
    private var currentIndex: Int = -1

    init(device: MTLDevice, maxFramesInFlight: Int, uniformLength: Int) {
        self.semaphore = DispatchSemaphore(value: max(1, maxFramesInFlight))

        var createdBuffers: [MTLBuffer] = []
        createdBuffers.reserveCapacity(maxFramesInFlight)

        for frame in 0..<maxFramesInFlight {
            if let buffer = device.makeBuffer(length: uniformLength, options: .storageModeShared) {
                buffer.label = "Uniform Buffer #\(frame)"
                createdBuffers.append(buffer)
            } else {
                vrmLog(
                    "[VRMUniformBufferRing] ⚠️ Failed to create uniform buffer for frame #\(frame)")
            }
        }

        if createdBuffers.count != maxFramesInFlight {
            vrmLog(
                "[VRMUniformBufferRing] Created \(createdBuffers.count)/\(maxFramesInFlight) uniform buffers"
            )
        }

        self.buffers = createdBuffers
    }

    /// Waits for an available buffer and returns it. Returns `nil` if no buffers were created.
    func acquireBuffer() -> MTLBuffer? {
        _ = semaphore.wait(timeout: .distantFuture)

        guard !buffers.isEmpty else {
            semaphore.signal()
            vrmLog("[VRMUniformBufferRing] ❌ No uniform buffers available")
            return nil
        }

        currentIndex = (currentIndex + 1) % buffers.count
        return buffers[currentIndex]
    }

    /// Signals the semaphore when a frame is aborted before the GPU completion handler is attached.
    func cancelFrame() {
        semaphore.signal()
    }

    /// Hooks the semaphore release to the provided command buffer's completion handler.
    func attachCompletionHandler(to commandBuffer: MTLCommandBuffer) {
        let semaphore = self.semaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
    }

    /// Provides read-only access to underlying buffers for strict validation.
    var allBuffers: [MTLBuffer] {
        buffers
    }
}
