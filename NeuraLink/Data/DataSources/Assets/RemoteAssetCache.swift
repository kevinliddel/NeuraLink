//
// RemoteAssetCache.swift
// NeuraLink
//
// Async resolver for on-demand assets. Returns a usable file URL for a
// SceneAsset by checking (in order):
//   1. In-actor resolved cache — short-circuits repeated calls in the
//      same app session without any FS work.
//   2. App bundle — keeps local dev + current Release build green while
//      the GLBs are still in "Copy Bundle Resources".
//   3. On-disk download cache at `<App Support>/hf-assets/<pathInRepo>`.
//   4. Direct HTTPS download from the public HuggingFace dataset.
//
// Single-flight: concurrent callers for the same asset share one Task.
// Reentrancy is fine — the actor serializes access to the `inFlight`
// table, and Task.value is safe to await from multiple suspended
// continuations.
//
// Why plain `URLSession` instead of `HubApi`: the dataset is public, but
// HubApi's default `TokenProvider.environment` auto-discovers HF tokens
// from `HF_TOKEN` env vars and `~/.cache/huggingface/token` files. iOS
// simulators inherit env vars from the launching shell, so a host-side
// CLI token leaks in and HF rejects it with 401 for cross-account or
// scoped-wrong reasons. The public init doesn't expose `tokenProvider`
// directly, so we can't opt out of token discovery. Going direct via
// the `huggingface.co/datasets/<repo>/resolve/main/<path>` URL bypasses
// auth entirely — that endpoint is anonymous-readable for public datasets.
//
// Created by Dedicatus on 29/05/2026.
//

import CryptoKit
import Foundation

actor RemoteAssetCache {
    static let shared = RemoteAssetCache()

    enum CacheError: Error {
        case assetNotFound
        case downloadFailed(Error)
        case httpStatus(Int)
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch(expected: String, actual: String)
    }

    private var resolved: [RemoteAssetRegistry: URL] = [:]
    private var inFlight: [RemoteAssetRegistry: Task<URL, Error>] = [:]

    private init() {}

    /// Resolves the on-disk URL for `asset`. Cheap when the bundle or the
    /// in-actor resolved cache satisfies the lookup; only the cold path
    /// touches the network.
    ///
    /// `onProgress` (optional) reports download progress as
    /// `(bytesWritten, bytesExpected)` — `bytesExpected` is `-1` when the
    /// server omits `Content-Length`. It fires only on the cold network path;
    /// bundle / on-disk / in-flight-share hits never call it. Callers that
    /// don't pass it keep the lighter, delegate-free download path.
    func url(
        for asset: RemoteAssetRegistry,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        if let cached = resolved[asset] {
            return cached
        }
        if let bundled = bundledURL(for: asset) {
            resolved[asset] = bundled
            return bundled
        }
        if let onDisk = Self.cachedURL(for: asset),
            FileManager.default.fileExists(atPath: onDisk.path) {
            // Cheap size check (one stat) heals files truncated by pre-hardening
            // downloads: purge and fall through to a fresh, verified download.
            if let expected = asset.integrity?.size,
                Self.fileSize(at: onDisk) != expected {
                nlLog(
                    "[RemoteAssetCache] Cached \(asset.pathInRepo) has wrong size — purging and re-downloading.",
                    level: .warning)
                try? FileManager.default.removeItem(at: onDisk)
            } else {
                resolved[asset] = onDisk
                return onDisk
            }
        }
        if let existing = inFlight[asset] {
            return try await existing.value
        }
        let task = Task<URL, Error> {
            try await Self.download(asset: asset, onProgress: onProgress)
        }
        inFlight[asset] = task
        defer { inFlight[asset] = nil }
        let url = try await task.value
        resolved[asset] = url
        return url
    }

    /// The on-disk URL when `asset` is bundled or already downloaded and
    /// size-verified; nil otherwise. Never touches the network — used at
    /// launch to restore optional models without forcing a download.
    func localURLIfAvailable(for asset: RemoteAssetRegistry) -> URL? {
        if let cached = resolved[asset] { return cached }
        if let bundled = bundledURL(for: asset) { return bundled }
        guard let onDisk = Self.cachedURL(for: asset), FileManager.default.fileExists(atPath: onDisk.path) else {
            return nil
        }
        if let expected = asset.integrity?.size, Self.fileSize(at: onDisk) != expected { return nil }
        return onDisk
    }

    /// Drops any cached/in-flight resolution for `asset` so the next `url(for:)`
    /// re-downloads from scratch. Cancels a hung in-flight download — used by
    /// the loading-screen "Retry" affordance when a first-launch fetch stalls.
    func invalidate(_ asset: RemoteAssetRegistry) {
        inFlight[asset]?.cancel()
        inFlight[asset] = nil
        resolved[asset] = nil
    }

    // MARK: - Path resolution

    private func bundledURL(for asset: RemoteAssetRegistry) -> URL? {
        let resource = (asset.filename as NSString).deletingPathExtension
        let rawExt = (asset.filename as NSString).pathExtension
        let ext: String? = rawExt.isEmpty ? nil : rawExt
        if let url = Bundle.main.url(forResource: resource, withExtension: ext) {
            return url
        }
        guard let subdir = asset.bundleSubdirectory else { return nil }
        return Bundle.main.url(
            forResource: resource, withExtension: ext,
            subdirectory: subdir)
    }

    private static func cachedURL(for asset: RemoteAssetRegistry) -> URL? {
        guard let base = hfDownloadBase() else { return nil }
        return base.appendingPathComponent(asset.pathInRepo)
    }

    private static func hfDownloadBase() -> URL? {
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else { return nil }
        let dir = support.appendingPathComponent("hf-assets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Download

    /// Downloads `asset` from the public HuggingFace dataset over plain
    /// HTTPS — no auth, no token discovery, no HubApi caching layer.
    /// Resolves redirects automatically (URLSession default) so the CDN
    /// hop to xet-bridge is transparent.
    ///
    /// When `onProgress` is supplied, the download runs through a delegate-backed
    /// session that reports byte counts; otherwise it uses the lighter
    /// delegate-free `download(from:)`.
    ///
    /// Downloads land at a `.part` sibling first and are size- + SHA-256-verified
    /// against the asset's pinned `integrity` before being renamed into place,
    /// so a truncated or tampered fetch never enters the cache. A mismatch is
    /// deleted and retried once, then surfaced as a `CacheError`.
    private static func download(
        asset: RemoteAssetRegistry,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> URL {
        guard let target = cachedURL(for: asset) else {
            throw CacheError.assetNotFound
        }
        let parent = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
        }

        guard let remoteURL = asset.remoteURL else {
            throw CacheError.assetNotFound
        }

        let integrity = asset.integrity
        if integrity == nil {
            nlLog(
                "[RemoteAssetCache] No pinned integrity for \(asset.pathInRepo) — accepting download unverified.",
                level: .warning)
        }
        let partURL = target.appendingPathExtension("part")

        for attempt in 0..<2 {
            do {
                try await fetch(
                    from: remoteURL, to: partURL, expectedSize: integrity?.size, onProgress: onProgress)
                try verify(fileAt: partURL, against: integrity)
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: partURL, to: target)
                return target
            } catch {
                switch error as? CacheError {
                case .sizeMismatch?, .checksumMismatch?:
                    // Corrupt in transit, or a partial left by an older
                    // version of the file: throw it away and go once more
                    // from the start. Only this earns the retry.
                    try? FileManager.default.removeItem(at: partURL)
                    guard attempt == 0 else { throw error }
                    nlLog(
                        "[RemoteAssetCache] \(asset.pathInRepo) failed verification (\(error)) — retrying once.",
                        level: .warning)
                case .httpStatus(let code)? where (400..<500).contains(code):
                    // Nothing to resume for a file the server will not give.
                    try? FileManager.default.removeItem(at: partURL)
                    throw error
                default:
                    // Transport trouble: the partial stays, and the next
                    // attempt — or the next launch — continues from it.
                    throw error
                }
            }
        }
        // Unreachable: the loop either returns or throws on the second pass.
        throw CacheError.assetNotFound
    }

    // MARK: - Fetch (resumable)

    /// Fetches `remoteURL` into `partURL`, continuing from whatever an
    /// earlier attempt — or an earlier launch — left there, with an HTTP
    /// Range request. The partial file IS the resume state, so a transfer
    /// that died at 80% costs the last 20% next time, not a fresh start;
    /// on a slow link that is the difference between the library arriving
    /// and the same outfit being started over on every launch.
    ///
    /// Bytes arrive in the session's own chunks (`ResumableFetchDelegate`)
    /// and go straight to disk on the delegate queue: a per-byte async loop
    /// here was fine in release but crawled in the Debug builds tests run,
    /// and starved a fresh install that pulls the whole parts library.
    /// `nonisolated` so none of it can land on the main actor.
    ///
    /// Throws `CacheError` on HTTP/transport failure. The partial is kept on
    /// transport errors (the caller verifies it when it completes).
    /// `configuration` lets tests route the session through a stub protocol.
    nonisolated static func fetch(
        from remoteURL: URL,
        to partURL: URL,
        expectedSize: Int64?,
        configuration: URLSessionConfiguration = .default,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        var existing = max(0, fileSize(at: partURL))
        if let expectedSize {
            if existing > expectedSize {
                // Longer than the whole file: stale bytes from another version.
                try? FileManager.default.removeItem(at: partURL)
                existing = 0
            } else if existing == expectedSize {
                return  // complete; the caller verifies it
            }
        }
        var request = URLRequest(url: remoteURL)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let delegate = ResumableFetchDelegate(
            partURL: partURL, existing: existing, expectedSize: expectedSize, onProgress: onProgress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    // MARK: - Integrity verification

    /// Verifies `url` against the pinned `integrity`: size first (one stat),
    /// then a streaming SHA-256. No-op when `integrity` is nil. Internal (not
    /// private) so tests can exercise it directly.
    static func verify(
        fileAt url: URL,
        against integrity: RemoteAssetRegistry.AssetIntegrity?
    ) throws {
        guard let integrity else { return }
        let actualSize = fileSize(at: url)
        guard actualSize == integrity.size else {
            throw CacheError.sizeMismatch(expected: integrity.size, actual: actualSize)
        }
        let actualHash = try sha256Hex(of: url)
        guard actualHash == integrity.sha256 else {
            throw CacheError.checksumMismatch(
                expected: integrity.sha256, actual: actualHash)
        }
    }

    /// On-disk size of `url`, `-1` when unreadable (never matches a pin).
    static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Streaming SHA-256 (lowercase hex) — chunked reads keep peak memory flat
    /// even for the ~170 MB ONNX models.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done = false
        while !done {
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    done = true
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Resumable fetch delegate

/// Streams one ranged GET into the partial file, chunk by chunk, on the
/// session's serial delegate queue. 206 appends to what is held; 200 starts
/// the file over (the server ignored the range); 416 with bytes held means
/// nothing is left to send.
private final class ResumableFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partURL: URL
    private let expectedSize: Int64?
    private let onProgress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var wasCancelled = false
    private var handle: FileHandle?
    private var existing: Int64
    private var written: Int64 = 0
    private var total: Int64 = -1
    private var lastReported: Int64 = -1
    private var failure: Error?
    private var nothingLeft = false

    init(partURL: URL, existing: Int64, expectedSize: Int64?, onProgress: (@Sendable (Int64, Int64) -> Void)?) {
        self.partURL = partURL
        self.existing = existing
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.task = task
        self.continuation = continuation
        let cancelled = wasCancelled
        lock.unlock()
        if cancelled { task.cancel() } else { task.resume() }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            failure = RemoteAssetCache.CacheError.downloadFailed(URLError(.badServerResponse))
            return completionHandler(.cancel)
        }
        switch http.statusCode {
        case 206:
            break
        case 416 where existing > 0:
            nothingLeft = true
            return completionHandler(.cancel)
        case 200..<300:
            existing = 0  // the whole file is coming: start the partial over
        default:
            failure = RemoteAssetCache.CacheError.httpStatus(http.statusCode)
            return completionHandler(.cancel)
        }
        do {
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.truncate(atOffset: UInt64(existing))
            try handle.seekToEnd()
            self.handle = handle
        } catch {
            failure = RemoteAssetCache.CacheError.downloadFailed(error)
            return completionHandler(.cancel)
        }
        written = existing
        total = http.expectedContentLength > 0 ? existing + http.expectedContentLength : (expectedSize ?? -1)
        report()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handle, failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            if written - lastReported >= 65_536 { report() }
        } catch {
            failure = RemoteAssetCache.CacheError.downloadFailed(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        let result: Result<Void, Error>
        if nothingLeft {
            result = .success(())
        } else if let failure {
            result = .failure(failure)
        } else if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            lock.lock(); let byCaller = wasCancelled; lock.unlock()
            result = .failure(
                cancelled && byCaller ? CancellationError() : RemoteAssetCache.CacheError.downloadFailed(error))
        } else {
            report()
            result = .success(())
        }
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func report() {
        lastReported = written
        onProgress?(written, total)
    }
}
