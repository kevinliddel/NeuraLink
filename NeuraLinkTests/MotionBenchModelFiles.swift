//
//  MotionBenchModelFiles.swift
//  NeuraLinkTests
//
//  Where GeneratedMotionBench finds the ARDY-mini fp32 model files: a folder
//  named by NL_MOTION_MODEL_DIR; else files bundled with the tests (drop a
//  model folder's contents into the git-ignored NeuraLinkTests/MotionModels/
//  and they ride along to a phone); else, on a phone, a one-time download into
//  Caches (NL_MOTION_MODEL_DOWNLOAD=1) verified against model.json's SHA-256s.
//  The download base is Hugging Face's fp32 folder (gzip transports, inflated
//  with the Compression framework) unless NL_MOTION_MODEL_URL names another
//  base, such as `python3 -m http.server` run in a patched model folder on the
//  Mac, which serves the raw files; `.gz` in a served name still inflates.
//
//  Created by Dedicatus on 29/10/2026.
//

import Compression
import CryptoKit
import Foundation
import Testing

private final class BundleMarker {}

enum MotionBenchModelFiles {
    private static let huggingFace = "https://huggingface.co/intsuc/Llama-3-ARDY-Mini-Core40-Browser/resolve/main/fp32/"
    private static let files = ["model.json", "text_encoder.onnx", "denoiser.onnx", "decoder.onnx"]

    static func resolve(env: [String: String]) async throws -> URL {
        if let path = env["NL_MOTION_MODEL_DIR"], !path.isEmpty {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try #require(FileManager.default.fileExists(atPath: dir.appendingPathComponent("denoiser.onnx").path), "no denoiser.onnx in \(path)")
            return dir
        }
        if let bundled = bundledModelDirectory() {
            return bundled
        }
        try #require(env["NL_MOTION_MODEL_DOWNLOAD"] == "1", "set NL_MOTION_MODEL_DIR, bundle a model, or set NL_MOTION_MODEL_DOWNLOAD=1")
        let base = env["NL_MOTION_MODEL_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? huggingFace
        let gzipped = base == huggingFace
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = gzipped ? "ardy-mini-fp32" : "ardy-mini-" + String(base.hashValue.magnitude % 100_000)
        let dir = caches.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            try await download(name, from: base, gzipped: gzipped, into: dir)
        }
        try verify(dir)
        return dir
    }

    /// The folder holding bundled copies of all four files, if the test bundle
    /// carries them (a synchronized group flattens them next to each other).
    private static func bundledModelDirectory() -> URL? {
        let bundle = Bundle(for: BundleMarker.self)
        guard let manifest = bundle.url(forResource: "model", withExtension: "json") else { return nil }
        let dir = manifest.deletingLastPathComponent()
        let complete = files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        return complete ? dir : nil
    }

    private static func download(_ name: String, from base: String, gzipped: Bool, into dir: URL) async throws {
        let url = try #require(URL(string: base + name + (gzipped ? ".gz" : "")))
        let (temporary, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try #require(status == 200, "\(name): HTTP \(status)")
        let target = dir.appendingPathComponent(name)
        if gzipped {
            try GzipInflater.inflate(from: temporary, to: target)
            try? FileManager.default.removeItem(at: temporary)
        } else {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    /// model.json lists every file's SHA-256; a corrupt download is deleted so
    /// the next run fetches it again.
    private static func verify(_ dir: URL) throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("model.json"))) as? [String: Any]
        let entries = try #require(manifest?["files"] as? [String: [String: Any]])
        for name in files where name != "model.json" {
            let expected = try #require(entries[name]?["sha256"] as? String)
            let url = dir.appendingPathComponent(name)
            let actual = try sha256(of: url)
            if actual != expected {
                try? FileManager.default.removeItem(at: url)
                Issue.record("\(name): SHA-256 \(actual) != \(expected); deleted, run again")
            }
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Streaming gzip -> file inflate. gzip is a 10-byte header (plus optional
/// fields) around a raw DEFLATE stream, which Compression's zlib mode reads.
enum GzipInflater {
    enum Failure: Error { case notGzip, header, stream }

    static func inflate(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try skipHeader(input)

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 0), dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.stream }
        defer { compression_stream_destroy(&stream) }
        let chunk = 1 << 20
        let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { outBuffer.deallocate() }
        var finished = false
        var pending = Data()
        while !finished {
            if stream.src_size == 0 {
                pending = (try? input.read(upToCount: chunk)) ?? Data()
            }
            let flags = pending.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status: compression_status = pending.withUnsafeBytes { raw in
                if stream.src_size == 0, let basePointer = raw.bindMemory(to: UInt8.self).baseAddress {
                    stream.src_ptr = basePointer
                    stream.src_size = pending.count
                }
                stream.dst_ptr = outBuffer
                stream.dst_size = chunk
                return compression_stream_process(&stream, flags)
            }
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = chunk - stream.dst_size
                if produced > 0 { output.write(Data(bytes: outBuffer, count: produced)) }
                finished = status == COMPRESSION_STATUS_END
            default:
                throw Failure.stream
            }
        }
    }

    private static func skipHeader(_ input: FileHandle) throws {
        guard let fixed = try input.read(upToCount: 10), fixed.count == 10, fixed[0] == 0x1f, fixed[1] == 0x8b, fixed[2] == 8 else { throw Failure.notGzip }
        let flags = fixed[3]
        if flags & 0x04 != 0 {
            guard let lengthBytes = try input.read(upToCount: 2), lengthBytes.count == 2 else { throw Failure.header }
            let length = Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8
            _ = try input.read(upToCount: length)
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {
            while let byte = try input.read(upToCount: 1), byte.count == 1, byte[0] != 0 {}
        }
        if flags & 0x02 != 0 { _ = try input.read(upToCount: 2) }
    }
}
