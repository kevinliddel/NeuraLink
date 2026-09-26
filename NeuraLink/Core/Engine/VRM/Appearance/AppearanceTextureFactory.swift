//
//  AppearanceTextureFactory.swift
//  NeuraLink
//
//  Image → MTLTexture upload for donor textures, plus the coverage masks
//  that decide donor compatibility.
//
//  PNG data is decoded by PNGStraightDecoder so the upload is STRAIGHT
//  (non-premultiplied) RGBA: VRoid keeps real skin colour under the alpha-0
//  regions of a body texture (the parts its own outfit hides), and the
//  renderer draws body skin opaque, so a premultiplied upload would paint
//  those regions black on a recipient with a different outfit. Anything
//  else (JPEG, exotic PNGs) goes through the same CGContext path
//  TextureLoader uses. sRGB, no mipmaps, shared storage — like the
//  loader's base-colour textures.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal

nonisolated public enum AppearanceTextureFactory {

    public static func decode(_ imageData: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Upload

    /// Uploads encoded image bytes as an sRGB RGBA8 texture.
    public static func makeTexture(imageData: Data, device: MTLDevice) -> MTLTexture? {
        if let straight = PNGStraightDecoder.decode(imageData) {
            guard let texture = makeTexture(width: straight.width, height: straight.height, device: device)
            else { return nil }
            straight.pixels.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, straight.width, straight.height), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: straight.bytesPerRow)
            }
            return texture
        }
        guard let cgImage = decode(imageData) else { return nil }
        return makeTexture(from: cgImage, device: device)
    }

    /// CGImage fallback upload (premultiplied through CoreGraphics).
    public static func makeTexture(from cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = max(1, cgImage.width)
        let height = max(1, cgImage.height)
        guard let texture = makeTexture(width: width, height: height, device: device),
            let context = makeContext(width: width, height: height),
            let pixels = drawn(cgImage, into: context, width: width, height: height)
        else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: context.bytesPerRow)
        return texture
    }

    // MARK: - Coverage

    /// Painted-area masks on the coverage grid (row 0 = image top).
    /// `alpha`: texels with alpha ≥ 0.5 — right for MASK/BLEND slots.
    /// `color`: texels with any colour at all — right for slots the renderer
    /// draws opaque (body skin), where alpha is ignored.
    public static func coverageMasks(imageData: Data) -> (alpha: UVCoverageMask, color: UVCoverageMask)? {
        if let straight = PNGStraightDecoder.decode(imageData) {
            return coverageMasks(of: straight)
        }
        guard let cgImage = decode(imageData) else { return nil }
        return coverageMasks(of: cgImage)
    }

    public static func coverageMasks(of image: StraightRGBAImage) -> (alpha: UVCoverageMask, color: UVCoverageMask) {
        let res = UVCoverageMask.resolution
        var alphaGrid = [UInt8](repeating: 0, count: res * res)
        var colorGrid = [UInt8](repeating: 0, count: res * res)
        for y in 0..<res {
            let py = min(image.height - 1, (y * image.height + image.height / 2) / res)
            for x in 0..<res {
                let px = min(image.width - 1, (x * image.width + image.width / 2) / res)
                let p = image.pixel(x: px, y: py)
                alphaGrid[y * res + x] = p.a
                colorGrid[y * res + x] = max(p.r, p.g, p.b) > 8 ? 255 : 0
            }
        }
        return (UVCoverageMask.fromAlphaGrid(alphaGrid), UVCoverageMask.fromAlphaGrid(colorGrid))
    }

    /// CGImage fallback (premultiplied, so colour ⊆ alpha here).
    public static func coverageMasks(of cgImage: CGImage) -> (alpha: UVCoverageMask, color: UVCoverageMask) {
        let res = UVCoverageMask.resolution
        var alphaGrid = [UInt8](repeating: 0, count: res * res)
        var colorGrid = [UInt8](repeating: 0, count: res * res)
        if let context = makeContext(width: res, height: res),
            let pixels = drawn(cgImage, into: context, width: res, height: res) {
            let bytesPerRow = context.bytesPerRow
            let bytes = pixels.assumingMemoryBound(to: UInt8.self)
            for y in 0..<res {
                for x in 0..<res {
                    let o = y * bytesPerRow + x * 4
                    alphaGrid[y * res + x] = bytes[o + 3]
                    colorGrid[y * res + x] = max(bytes[o], bytes[o + 1], bytes[o + 2]) > 8 ? 255 : 0
                }
            }
        }
        return (UVCoverageMask.fromAlphaGrid(alphaGrid), UVCoverageMask.fromAlphaGrid(colorGrid))
    }

    /// Alpha-only convenience (tests, diagnostics).
    public static func alphaCoverage(of cgImage: CGImage) -> UVCoverageMask {
        coverageMasks(of: cgImage).alpha
    }

    // MARK: - Helpers

    private static func makeTexture(width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Plain draw: a bitmap context's first memory row is the image's top
    /// row, which is what Metal and glTF (v = 0 at the top) both expect —
    /// the same convention TextureLoader relies on. Nearest sampling so a
    /// down-scaled mask keeps hard edges.
    private static func drawn(_ image: CGImage, into context: CGContext, width: Int, height: Int)
        -> UnsafeMutableRawPointer? {
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.data
    }
}
