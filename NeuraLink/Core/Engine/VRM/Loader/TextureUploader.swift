//
//  TextureUploader.swift
//  NeuraLink
//
//  Encoded image bytes → Metal texture, shared by TextureLoader and
//  ParallelTextureLoader.
//
//  Straight alpha. glTF / VRM textures are straight (non-premultiplied),
//  as Unity and three-vrm read them, and the blend pipelines expect that
//  (sourceAlpha, oneMinusSourceAlpha). Drawing through a CGContext
//  premultiplies, which darkened every half-transparent texel — dark
//  fringes on hair tips and lashes — and zeroed the colour under alpha-0
//  texels that bilinear filtering still reads at an edge. PNGs are decoded
//  byte for byte by PNGStraightDecoder; anything else (JPEG, or a PNG that
//  must be downscaled) goes through ImageIO and is un-premultiplied after.
//
//  Mipmaps. Without them a texture seen small on screen aliases and
//  shimmers. They cost a third more texture memory.
//
//  Created by Dedicatus on 22/10/2026.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal

nonisolated enum TextureUploader {

    /// A texture for `imageData`, or nil when it can't be decoded. `sRGB`
    /// is false for normal maps and MToon data textures (shading shift,
    /// outline width, UV-animation mask). `maxSize` caps the longer side.
    static func makeTexture(
        device: MTLDevice, imageData: Data, sRGB: Bool, maxSize: Int = .max,
        withMipmaps: Bool, commandQueue: MTLCommandQueue?
    ) -> MTLTexture? {
        guard let image = straightPNG(imageData, maxSize: maxSize) ?? imageIO(imageData, maxSize: maxSize) else {
            return nil
        }
        return upload(image, device: device, sRGB: sRGB, withMipmaps: withMipmaps, commandQueue: commandQueue)
    }

    // MARK: - Decode

    struct Pixels {
        let width: Int
        let height: Int
        var rgba: [UInt8]
    }

    private static func straightPNG(_ data: Data, maxSize: Int) -> Pixels? {
        guard let image = PNGStraightDecoder.decode(data), max(image.width, image.height) <= maxSize else { return nil }
        return Pixels(width: image.width, height: image.height, rgba: image.pixels)
    }

    private static func imageIO(_ data: Data, maxSize: Int) -> Pixels? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let scale = maxSize < .max ? min(1.0, Double(maxSize) / Double(max(image.width, image.height))) : 1.0
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = Pixels(width: width, height: height, rgba: [UInt8](repeating: 0, count: width * height * 4))
        let drawn = pixels.rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        unpremultiply(&pixels.rgba)
        return pixels
    }

    /// CoreGraphics only draws premultiplied; divide it back out.
    static func unpremultiply(_ rgba: inout [UInt8]) {
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                rgba[index + channel] = UInt8(min(255, (Int(rgba[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
    }

    // MARK: - Upload

    private static func upload(
        _ pixels: Pixels, device: MTLDevice, sRGB: Bool, withMipmaps: Bool, commandQueue: MTLCommandQueue?
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
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed ? texture : base
    }
}
