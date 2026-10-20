//
//  RemoteAssetCacheResumeTests.swift
//  NeuraLinkTests
//
//  The resumable fetch behind every dataset download: a partial file is
//  continued with a Range request, a server that ignores the range is
//  tolerated, and a missing file fails fast with its status. Served by a
//  URLProtocol stub so nothing touches the network.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Testing
@testable import NeuraLink

/// Serves one deterministic blob at `stub.test/blob` (honouring Range),
/// the same blob at `/norange` while ignoring Range, and 404 elsewhere.
nonisolated final class RangeStubProtocol: URLProtocol {
    static let blob: Data = {
        var data = Data(count: 300_000)
        for i in 0..<data.count { data[i] = UInt8((i &* 31) & 0xFF) }
        return data
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let blob = Self.blob
        func send(_ status: Int, headers: [String: String], body: Data) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client.urlProtocol(self, didLoad: body) }
            client.urlProtocolDidFinishLoading(self)
        }
        switch url.path {
        case "/blob":
            if let range = request.value(forHTTPHeaderField: "Range"),
               range.hasPrefix("bytes="), let start = Int(range.dropFirst(6).dropLast()) {
                guard start < blob.count else {
                    return send(416, headers: ["Content-Range": "bytes */\(blob.count)"], body: Data())
                }
                let rest = blob[start...]
                send(206, headers: [
                    "Content-Length": "\(rest.count)",
                    "Content-Range": "bytes \(start)-\(blob.count - 1)/\(blob.count)"
                ], body: Data(rest))
            } else {
                send(200, headers: ["Content-Length": "\(blob.count)"], body: blob)
            }
        case "/norange":
            send(200, headers: ["Content-Length": "\(blob.count)"], body: blob)
        default:
            send(404, headers: [:], body: Data())
        }
    }

    override func stopLoading() {}
}

@Suite("Remote asset cache — resumable fetch", .serialized)
struct RemoteAssetCacheResumeTests {

    private func scratchFile(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume_\(tag)_\(UUID().uuidString).vrm.part")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// A session configuration that routes every request through the stub.
    private static var stubbed: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStubProtocol.self]
        return configuration
    }

    private func withStub<T>(_ body: () async throws -> T) async rethrows -> T {
        try await body()
    }

    @Test("A fresh fetch writes the whole blob and reports progress")
    func freshFetch() async throws {
        let part = scratchFile("fresh")
        defer { try? FileManager.default.removeItem(at: part) }
        let seen = ProgressSink()
        try await withStub {
            try await RemoteAssetCache.fetch(
                from: URL(string: "https://stub.test/blob")!, to: part,
                expectedSize: Int64(RangeStubProtocol.blob.count), configuration: Self.stubbed, onProgress: { seen.record($0, $1) })
        }
        #expect(try Data(contentsOf: part) == RangeStubProtocol.blob)
        #expect(seen.last == Int64(RangeStubProtocol.blob.count))
    }

    @Test("A partial file is continued with a Range request, not restarted")
    func resumesPartial() async throws {
        let part = scratchFile("partial")
        defer { try? FileManager.default.removeItem(at: part) }
        let head = RangeStubProtocol.blob.prefix(120_000)
        try head.write(to: part)
        let seen = ProgressSink()
        try await withStub {
            try await RemoteAssetCache.fetch(
                from: URL(string: "https://stub.test/blob")!, to: part,
                expectedSize: Int64(RangeStubProtocol.blob.count), configuration: Self.stubbed, onProgress: { seen.record($0, $1) })
        }
        #expect(try Data(contentsOf: part) == RangeStubProtocol.blob)
        // Progress counts from the resumed offset, so the first report is past the head.
        #expect((seen.first ?? 0) >= Int64(head.count))
    }

    @Test("A server that ignores the range sends everything and the partial is replaced")
    func serverIgnoresRange() async throws {
        let part = scratchFile("norange")
        defer { try? FileManager.default.removeItem(at: part) }
        try Data(repeating: 0xEE, count: 50_000).write(to: part)
        try await withStub {
            try await RemoteAssetCache.fetch(
                from: URL(string: "https://stub.test/norange")!, to: part,
                expectedSize: Int64(RangeStubProtocol.blob.count), configuration: Self.stubbed, onProgress: nil)
        }
        #expect(try Data(contentsOf: part) == RangeStubProtocol.blob)
    }

    @Test("A complete partial is not fetched again")
    func completePartialShortCircuits() async throws {
        let part = scratchFile("complete")
        defer { try? FileManager.default.removeItem(at: part) }
        try RangeStubProtocol.blob.write(to: part)
        // A plain session cannot reach stub.test, so success proves no request was made.
        try await RemoteAssetCache.fetch(
            from: URL(string: "https://stub.test/blob")!, to: part,
            expectedSize: Int64(RangeStubProtocol.blob.count), configuration: .ephemeral, onProgress: nil)
        #expect(try Data(contentsOf: part) == RangeStubProtocol.blob)
    }

    @Test("A missing file fails with its HTTP status and is treated as permanent by the parts downloader")
    func missingFileFailsFast() async throws {
        let part = scratchFile("missing")
        defer { try? FileManager.default.removeItem(at: part) }
        await withStub {
            do {
                try await RemoteAssetCache.fetch(
                    from: URL(string: "https://stub.test/nowhere")!, to: part, expectedSize: 10,
                    configuration: Self.stubbed, onProgress: nil)
                Issue.record("expected an HTTP failure")
            } catch {
                guard case RemoteAssetCache.CacheError.httpStatus(let code) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(code == 404)
                #expect(PartsLibraryDownloader.isPermanentFailure(error))
            }
        }
        #expect(!PartsLibraryDownloader.isPermanentFailure(RemoteAssetCache.CacheError.downloadFailed(URLError(.timedOut))))
        #expect(!PartsLibraryDownloader.isPermanentFailure(RemoteAssetCache.CacheError.httpStatus(503)))
    }
}

/// Thread-safe recorder for progress callbacks.
nonisolated final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func record(_ written: Int64, _ total: Int64) {
        lock.lock(); values.append(written); lock.unlock()
    }
    var first: Int64? { lock.lock(); defer { lock.unlock() }; return values.first }
    var last: Int64? { lock.lock(); defer { lock.unlock() }; return values.last }
}
