//
//  PNGStraightDecoder.swift
//  NeuraLink
//
//  Minimal PNG decoder that returns STRAIGHT (non-premultiplied) 8-bit RGBA.
//  ImageIO may premultiply on decode (it does on iOS for many PNGs), which
//  zeroes the colour under alpha-0 texels — exactly the skin colour VRoid
//  keeps under a body texture's outfit holes. Donor uploads need that colour
//  (body skin is drawn opaque), so the texture bytes are decoded here and
//  ImageIO is only the fallback for anything this decoder doesn't handle
//  (JPEG, 16-bit, palette, interlaced).
//
//  Supports: bit depth 8, colour types 0/2/4/6, non-interlaced, single or
//  multiple IDAT chunks. Inflate via the Compression framework
//  (COMPRESSION_ZLIB = raw DEFLATE, so the 2-byte zlib header is skipped).
//

import Compression
import Foundation

nonisolated public struct StraightRGBAImage: Sendable {
    public let width: Int
    public let height: Int
    /// Tightly packed RGBA, row 0 = top.
    public let pixels: [UInt8]

    public var bytesPerRow: Int { width * 4 }

    @inline(__always)
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let o = (y * width + x) * 4
        return (pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3])
    }
}

nonisolated public enum PNGStraightDecoder {
    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func decode(_ data: Data) -> StraightRGBAImage? {
        let bytes = [UInt8](data)
        guard bytes.count > 33, Array(bytes[0..<8]) == signature else { return nil }

        var width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0
        var idat: [UInt8] = []
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = Int(readUInt32(bytes, offset))
            let typeStart = offset + 4
            guard typeStart + 4 + length + 4 <= bytes.count else { return nil }
            let type = readUInt32(bytes, typeStart)
            let dataStart = typeStart + 4
            switch type {
            case 0x4948_4452:  // IHDR
                guard length >= 13 else { return nil }
                width = Int(readUInt32(bytes, dataStart))
                height = Int(readUInt32(bytes, dataStart + 4))
                bitDepth = Int(bytes[dataStart + 8])
                colorType = Int(bytes[dataStart + 9])
                interlace = Int(bytes[dataStart + 12])
            case 0x4944_4154:  // IDAT
                idat.append(contentsOf: bytes[dataStart..<(dataStart + length)])
            case 0x4945_4E44:  // IEND
                offset = bytes.count
                continue
            default:
                break
            }
            offset = dataStart + length + 4  // + CRC
        }

        guard width > 0, height > 0, bitDepth == 8, interlace == 0, !idat.isEmpty else { return nil }
        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 4: channels = 2
        case 6: channels = 4
        default: return nil
        }
        // Guard against absurd allocations from a corrupt header.
        guard width <= 16_384, height <= 16_384 else { return nil }

        let stride = width * channels
        let rawSize = height * (stride + 1)
        guard let raw = inflate(idat, expectedSize: rawSize) else { return nil }

        var out = [UInt8](repeating: 255, count: width * height * 4)
        var prev = [UInt8](repeating: 0, count: stride)
        var cur = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            let rowStart = y * (stride + 1)
            let filter = raw[rowStart]
            for i in 0..<stride { cur[i] = raw[rowStart + 1 + i] }
            guard unfilter(&cur, prev: prev, filter: filter, bpp: channels) else { return nil }
            expand(row: cur, channels: channels, width: width, into: &out, rowOffset: y * width * 4)
            swap(&prev, &cur)
        }
        return StraightRGBAImage(width: width, height: height, pixels: out)
    }

    // MARK: - Helpers

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    private static func inflate(_ zlibData: [UInt8], expectedSize: Int) -> [UInt8]? {
        // zlib stream = 2-byte header + raw DEFLATE + 4-byte Adler-32.
        guard zlibData.count > 6 else { return nil }
        var out = [UInt8](repeating: 0, count: expectedSize)
        let produced = zlibData.withUnsafeBufferPointer { src -> Int in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(
                    dst.baseAddress!, expectedSize,
                    src.baseAddress! + 2, zlibData.count - 2,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return produced == expectedSize ? out : nil
    }

    private static func unfilter(_ row: inout [UInt8], prev: [UInt8], filter: UInt8, bpp: Int) -> Bool {
        let n = row.count
        switch filter {
        case 0:
            return true
        case 1:
            for i in bpp..<n { row[i] = row[i] &+ row[i - bpp] }
        case 2:
            for i in 0..<n { row[i] = row[i] &+ prev[i] }
        case 3:
            for i in 0..<n {
                let left = i >= bpp ? Int(row[i - bpp]) : 0
                row[i] = row[i] &+ UInt8((left + Int(prev[i])) / 2)
            }
        case 4:
            for i in 0..<n {
                let a = i >= bpp ? Int(row[i - bpp]) : 0
                let b = Int(prev[i])
                let c = i >= bpp ? Int(prev[i - bpp]) : 0
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                row[i] = row[i] &+ UInt8(pred)
            }
        default:
            return false
        }
        return true
    }

    private static func expand(row: [UInt8], channels: Int, width: Int, into out: inout [UInt8], rowOffset: Int) {
        switch channels {
        case 4:
            for x in 0..<width {
                let s = x * 4, d = rowOffset + x * 4
                out[d] = row[s]; out[d + 1] = row[s + 1]; out[d + 2] = row[s + 2]; out[d + 3] = row[s + 3]
            }
        case 3:
            for x in 0..<width {
                let s = x * 3, d = rowOffset + x * 4
                out[d] = row[s]; out[d + 1] = row[s + 1]; out[d + 2] = row[s + 2]
            }
        case 2:
            for x in 0..<width {
                let s = x * 2, d = rowOffset + x * 4
                out[d] = row[s]; out[d + 1] = row[s]; out[d + 2] = row[s]; out[d + 3] = row[s + 1]
            }
        default:
            for x in 0..<width {
                let d = rowOffset + x * 4
                out[d] = row[x]; out[d + 1] = row[x]; out[d + 2] = row[x]
            }
        }
    }
}
