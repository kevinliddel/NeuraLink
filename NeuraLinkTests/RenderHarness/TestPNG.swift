//
//  TestPNG.swift
//  NeuraLinkTests
//
//  Writes straight (non-premultiplied) RGBA8 as a PNG, byte for byte. The
//  render probes need texels whose colour survives under alpha 0 (the alpha
//  fringe case), which any CoreGraphics path would premultiply away. Stored
//  (uncompressed) deflate blocks keep the encoder a few dozen lines.
//
//  Created by Dedicatus on 22/10/2026.
//

import Foundation

enum TestPNG {

    /// `rgba` is width × height × 4 bytes, row 0 at the top.
    static func encode(width: Int, height: Int, rgba: [UInt8]) -> Data {
        precondition(rgba.count == width * height * 4)
        var raw = Data(capacity: (width * 4 + 1) * height)
        for row in 0..<height {
            raw.append(0)  // filter: none
            raw.append(contentsOf: rgba[(row * width * 4)..<((row + 1) * width * 4)])
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 6, 0, 0, 0])  // 8-bit, RGBA, deflate, no filter, no interlace
        png.appendChunk("IHDR", header)
        png.appendChunk("IDAT", zlibStored(raw))
        png.appendChunk("IEND", Data())
        return png
    }

    /// A solid `size`² image.
    static func solid(size: Int, _ pixel: (UInt8, UInt8, UInt8, UInt8)) -> Data {
        encode(width: size, height: size, rgba: Array(repeating: [pixel.0, pixel.1, pixel.2, pixel.3], count: size * size)
            .flatMap { $0 })
    }

    private static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let length = min(65_535, bytes.count - offset)
            let isLast = offset + length >= bytes.count
            out.append(isLast ? 1 : 0)
            out.append(UInt8(length & 0xFF))
            out.append(UInt8(length >> 8))
            out.append(UInt8(~length & 0xFF))
            out.append(UInt8((~length >> 8) & 0xFF))
            out.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        } while offset < bytes.count
        var adlerA: UInt32 = 1
        var adlerB: UInt32 = 0
        for byte in bytes {
            adlerA = (adlerA + UInt32(byte)) % 65_521
            adlerB = (adlerB + adlerA) % 65_521
        }
        out.appendBigEndian((adlerB << 16) | adlerA)
        return out
    }

    fileprivate static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        appendBigEndian(UInt32(body.count))
        let typed = Data(type.utf8) + body
        append(typed)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in typed { crc = TestPNG.crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        appendBigEndian(crc ^ 0xFFFF_FFFF)
    }
}
