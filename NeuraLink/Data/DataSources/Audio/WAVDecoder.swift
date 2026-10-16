//
//  WAVDecoder.swift
//  NeuraLink
//
//  Minimal RIFF/WAVE reader for the utterance the Silero wrapper hands
//  back (`voiceEnded(withWavData:)`): 16-bit PCM or 32-bit float, any
//  channel count (mixed down to mono). Enough for feature extraction; not
//  a general audio importer.
//
//  Created by Dedicatus on 16/10/2026.
//

import Foundation

enum WAVDecoder {

    struct Decoded: Equatable {
        let samples: [Float]
        let sampleRate: Double
    }

    static func decode(_ data: Data) -> Decoded? {
        guard data.count >= 12, data[0..<4] == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { return nil }
        var offset = 12
        var format: (tag: UInt16, channels: Int, rate: Double, bits: Int)?
        while offset + 8 <= data.count {
            let id = String(bytes: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(readUInt32(data, at: offset + 4))
            let body = offset + 8
            guard body + size <= data.count || id == "data" else { return nil }
            if id == "fmt ", size >= 16 {
                format = (
                    tag: readUInt16(data, at: body),
                    channels: Int(readUInt16(data, at: body + 2)),
                    rate: Double(readUInt32(data, at: body + 4)),
                    bits: Int(readUInt16(data, at: body + 14)))
            } else if id == "data", let format {
                let end = min(data.count, body + size)
                return Decoded(samples: samples(data[body..<end], format: format), sampleRate: format.rate)
            }
            offset = body + size + (size % 2)
        }
        return nil
    }

    private static func samples(_ bytes: Data, format: (tag: UInt16, channels: Int, rate: Double, bits: Int)) -> [Float] {
        let channels = max(1, format.channels)
        var mono: [Float] = []
        if format.tag == 3, format.bits == 32 {
            let count = bytes.count / 4
            mono.reserveCapacity(count / channels)
            var index = 0
            while index + channels <= count {
                var sum: Float = 0
                for channel in 0..<channels { sum += readFloat(bytes, at: bytes.startIndex + (index + channel) * 4) }
                mono.append(sum / Float(channels))
                index += channels
            }
        } else if format.tag == 1, format.bits == 16 {
            let count = bytes.count / 2
            mono.reserveCapacity(count / channels)
            var index = 0
            while index + channels <= count {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += Float(Int16(bitPattern: readUInt16(bytes, at: bytes.startIndex + (index + channel) * 2))) / 32_768
                }
                mono.append(sum / Float(channels))
                index += channels
            }
        }
        return mono
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readUInt16(data, at: offset)) | UInt32(readUInt16(data, at: offset + 2)) << 16
    }

    private static func readFloat(_ data: Data, at offset: Int) -> Float {
        Float(bitPattern: readUInt32(data, at: offset))
    }

    /// Test and preview helper: 16-bit mono PCM container around samples.
    static func encode16(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * 32_767)
            pcm.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value)))
            pcm.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value) >> 8))
        }
        var out = Data()
        out.append(Data("RIFF".utf8))
        out.append(uint32(UInt32(36 + pcm.count)))
        out.append(Data("WAVEfmt ".utf8))
        out.append(uint32(16))
        out.append(uint16(1))
        out.append(uint16(1))
        out.append(uint32(UInt32(sampleRate)))
        out.append(uint32(UInt32(sampleRate * 2)))
        out.append(uint16(2))
        out.append(uint16(16))
        out.append(Data("data".utf8))
        out.append(uint32(UInt32(pcm.count)))
        out.append(pcm)
        return out
    }

    private static func uint16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
