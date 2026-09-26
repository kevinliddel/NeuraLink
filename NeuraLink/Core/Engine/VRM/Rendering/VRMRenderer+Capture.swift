//
//  VRMRenderer+Capture.swift
//  NeuraLink
//
//  One-shot frame capture for the photoshoot share
//  (docs/MEMORY_OWNERSHIP_PLAN.md §M2). The next presented frame is blitted
//  into a CPU-readable texture and converted to a UIImage on completion.
//  Requires `mtkView.framebufferOnly = false` for that frame (set by
//  `VRMMetalState.captureFrame`).
//
//  Created by Dedicatus on 27/09/2026.
//

import Metal
import MetalKit
import UIKit

extension VRMRenderer {

    /// Queues a capture of the next drawn frame.
    public func requestFrameCapture(_ completion: @escaping @Sendable (UIImage?) -> Void) {
        captureLock.lock()
        pendingCapture = completion
        captureLock.unlock()
    }

    /// Called from `draw(in:)` after the scene is encoded and before
    /// `present`. Copies the drawable into a shared-storage texture and
    /// converts it when the command buffer completes.
    func encodeCaptureIfRequested(view: MTKView, commandBuffer: MTLCommandBuffer) {
        captureLock.lock()
        let request = pendingCapture
        pendingCapture = nil
        captureLock.unlock()
        guard let request else { return }
        guard let drawable = view.currentDrawable, !drawable.texture.isFramebufferOnly,
              let target = makeReadbackTexture(like: drawable.texture),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            request(nil)
            return
        }
        blit.copy(from: drawable.texture, to: target)
        blit.endEncoding()
        let scale = view.contentScaleFactor
        let deliver = request
        commandBuffer.addCompletedHandler { _ in
            deliver(FrameImageConverter.image(from: target, scale: scale))
        }
    }

    private func makeReadbackTexture(like source: MTLTexture) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}

/// BGRA8 texture → UIImage. Pure and testable via `image(bgraBytes:)`.
nonisolated enum FrameImageConverter {

    static func image(from texture: MTLTexture, scale: CGFloat) -> UIImage? {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return image(bgraBytes: bytes, width: width, height: height, scale: scale)
    }

    static func image(bgraBytes: [UInt8], width: Int, height: Int, scale: CGFloat = 1) -> UIImage? {
        guard width > 0, height > 0, bgraBytes.count >= width * height * 4 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bgraBytes) as CFData),
              let cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
