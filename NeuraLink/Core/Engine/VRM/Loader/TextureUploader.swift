//
//  TextureUploader.swift
//  NeuraLink
//
//  Encoded image bytes → Metal texture, shared by TextureLoader and
//  ParallelTextureLoader.
//
//  Straight alpha. glTF / VRM textures are straight (non-premultiplied), as
//  Unity and three-vrm read them, and the blend pipelines expect that
//  (sourceAlpha, oneMinusSourceAlpha). ImageIO hands PNGs with alpha back
//  premultiplied on iOS, and drawing through a CGContext premultiplies, which
//  darkened every half-transparent texel (dark fringes on hair tips and
//  lashes). vImage divides the alpha back out. What it can't restore is the
//  colour under a fully transparent texel; only a byte-exact PNG decode keeps
//  that, and PNGStraightDecoder is ~150× slower than ImageIO (minutes for
//  one character in a Debug build), so it stays with the customization
//  path that needs it.
//
//  Mipmaps. Without them a texture seen small on screen aliases and
//  shimmers. They cost a third more texture memory. The mip blits are
//  committed without waiting; the loader waits once for all of them
//  (`MipmapWork`) before the textures are drawn.
//
//  Created by Dedicatus on 22/10/2026.
//

import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Metal

/// The mipmap blits a loader committed; `wait()` blocks until all are done.
/// Rendering runs on another queue, so the textures must not be drawn before.
nonisolated final class MipmapWork: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [MTLCommandBuffer] = []

    func add(_ commandBuffer: MTLCommandBuffer) {
        lock.withLock { pending.append(commandBuffer) }
    }

    func wait() {
        let buffers = lock.withLock { () -> [MTLCommandBuffer] in
            defer { pending.removeAll() }
            return pending
        }
        for buffer in buffers { buffer.waitUntilCompleted() }
    }
}

nonisolated enum TextureUploader {

    /// A texture for `imageData`, or nil when it can't be decoded. `sRGB` is
    /// false for normal maps and MToon data textures (shading shift, outline
    /// width, UV-animation mask). `maxSize` caps the longer side. With
    /// `pending`, the mip blit is recorded there instead of waited for.
    static func makeTexture(
        device: MTLDevice, imageData: Data, sRGB: Bool, maxSize: Int = .max,
        withMipmaps: Bool, commandQueue: MTLCommandQueue?, pending: MipmapWork? = nil
    ) -> MTLTexture? {
        guard let pixels = decode(imageData, maxSize: maxSize) else { return nil }
        return upload(pixels, device: device, sRGB: sRGB, withMipmaps: withMipmaps,
                      commandQueue: commandQueue, pending: pending)
    }

    // MARK: - Decode

    struct Pixels {
        let width: Int
        let height: Int
        var rgba: [UInt8]
    }

    private static func decode(_ data: Data, maxSize: Int) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let scale = maxSize < .max ? min(1.0, Double(maxSize) / Double(max(image.width, image.height))) : 1.0
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = Pixels(width: width, height: height, rgba: [UInt8](repeating: 0, count: width * height * 4))
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let decoded = pixels.rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress, let context = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard hasAlpha else { return true }
            var vImage = vImage_Buffer(
                data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageUnpremultiplyData_RGBA8888(&vImage, &vImage, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        return decoded ? pixels : nil
    }

    // MARK: - Upload

    private static func upload(
        _ pixels: Pixels, device: MTLDevice, sRGB: Bool, withMipmaps: Bool,
        commandQueue: MTLCommandQueue?, pending: MipmapWork?
    ) -> MTLTexture? {
        let format: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm
        let staging = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: pixels.width, height: pixels.height, mipmapped: false)
        staging.usage = [.shaderRead]
        staging.storageMode = .shared
        guard let base = device.makeTexture(descriptor: staging) else { return nil }
        pixels.rgba.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            base.replace(
                region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                withBytes: address, bytesPerRow: pixels.width * 4)
        }
        guard withMipmaps, max(pixels.width, pixels.height) > 1,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return base }

        let mipped = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: pixels.width, height: pixels.height, mipmapped: true)
        mipped.usage = [.shaderRead, .renderTarget]
        mipped.storageMode = .private
        guard let texture = device.makeTexture(descriptor: mipped),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return base }
        blit.copy(
            from: base, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: pixels.width, height: pixels.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        if let pending {
            pending.add(commandBuffer)
        } else {
            commandBuffer.waitUntilCompleted()
        }
        return texture
    }
}
