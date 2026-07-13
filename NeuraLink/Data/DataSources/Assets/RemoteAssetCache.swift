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

        let urlString =
            "https://huggingface.co/datasets/\(RemoteAssetRegistry.repoID)/resolve/main/\(asset.pathInRepo)"
        guard let remoteURL = URL(string: urlString) else {
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
            try? FileManager.default.removeItem(at: partURL)
            do {
                try await fetch(from: remoteURL, to: partURL, onProgress: onProgress)
                try verify(fileAt: partURL, against: integrity)
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: partURL, to: target)
                return target
            } catch {
                try? FileManager.default.removeItem(at: partURL)
                // Only an integrity mismatch earns the single retry — it's the
                // signature of a corrupt-in-transit fetch that a second attempt
                // can plausibly fix. Transport/HTTP errors keep their original
                // fail-fast behavior (callers own their own retry policy).
                let isIntegrityFailure: Bool
                switch error as? CacheError {
                case .sizeMismatch, .checksumMismatch: isIntegrityFailure = true
                default: isIntegrityFailure = false
                }
                guard isIntegrityFailure, attempt == 0 else { throw error }
                nlLog(
                    "[RemoteAssetCache] \(asset.pathInRepo) failed verification (\(error)) — retrying once.",
                    level: .warning)
            }
        }
        // Unreachable: the loop either returns or throws on the second pass.
        throw CacheError.assetNotFound
    }

    /// Fetches `remoteURL` into `destination` (replacing it), via the
    /// delegate-backed progress path or the plain one. Throws `CacheError`
    /// on HTTP/transport failure.
    private static func fetch(
        from remoteURL: URL,
        to destination: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        if let onProgress {
            try await downloadWithProgress(
                from: remoteURL, to: destination, onProgress: onProgress)
            return
        }
        do {
            let (downloadedTempURL, response) = try await URLSession.shared.download(
                from: remoteURL)
            if let http = response as? HTTPURLResponse,
                !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: downloadedTempURL)
                throw CacheError.httpStatus(http.statusCode)
            }
            try FileManager.default.moveItem(at: downloadedTempURL, to: destination)
        } catch let err as CacheError {
            throw err
        } catch {
            throw CacheError.downloadFailed(error)
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

    /// Downloads with byte-progress via a dedicated delegate-backed session.
    /// The delegate moves the temp file to `destination` (it's deleted the
    /// moment its callback returns) and resumes the continuation, so this
    /// bridges the classic download-task API into async/await. Cancelling the
    /// awaiting task cancels the underlying `URLSessionDownloadTask`.
    private static func downloadWithProgress(
        from remoteURL: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let delegate = DownloadProgressDelegate(
            destination: destination, onProgress: onProgress)
        let session = URLSession(
            configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                delegate.setContinuation(continuation)
                let task = session.downloadTask(with: remoteURL)
                delegate.attach(task)
                task.resume()
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

// MARK: - Progress delegate

/// Bridges a `URLSessionDownloadTask` into async/await while forwarding
/// byte-progress. On completion it moves the temp file into `destination` (the
/// system deletes it once `didFinishDownloadingTo` returns) and resumes the
/// continuation exactly once. Progress is throttled so a multi-hundred-MB
/// fetch doesn't flood the main actor.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var lastReported: Int64 = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var didResume = false
    private var task: URLSessionDownloadTask?
    private var wasCancelled = false
    /// Transport-error recoveries left in this download: a dropped connection
    /// mid-fetch continues from the partial bytes via URLSession resume data
    /// instead of failing the whole 100 MB fetch back to the caller.
    private var resumeAttemptsLeft = 2

    init(destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let cancelled = wasCancelled
        lock.unlock()
        // Closes the race where cancel() lands between an errored task and its
        // resume-data replacement being attached.
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    /// Resumes the continuation at most once (finish, HTTP error, or transport
    /// error can all race).
    private func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !didResume, let continuation else { lock.unlock(); return }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let atEnd = totalBytesExpectedToWrite > 0
            && totalBytesWritten >= totalBytesExpectedToWrite
        // Report the first callback, then every ~64 KB, plus the final one. Small
        // enough that a slow (but live) download still shows movement and keeps
        // the stall detector fed; coarse enough not to flood the main actor.
        let shouldReport = lastReported == 0
            || totalBytesWritten - lastReported >= 65_536
            || atEnd
        if shouldReport { lastReported = totalBytesWritten }
        lock.unlock()
        if shouldReport { onProgress(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
            !(200..<300).contains(http.statusCode) {
            resume(.failure(RemoteAssetCache.CacheError.httpStatus(http.statusCode)))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            resume(.success(destination))
        } catch {
            resume(.failure(RemoteAssetCache.CacheError.downloadFailed(error)))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Fires after `didFinishDownloadingTo` on success (a no-op then, since
        // the continuation already resumed) or on transport failure/cancel.
        guard let error else { return }

        let nsError = error as NSError
        let isCancel =
            nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        lock.lock()
        let canResume = !isCancel && !wasCancelled && !didResume
            && resumeData != nil && resumeAttemptsLeft > 0
        if canResume { resumeAttemptsLeft -= 1 }
        lock.unlock()

        if canResume, let resumeData {
            nlLog(
                "[RemoteAssetCache] Download interrupted (\(nsError.code)) — resuming from partial data.",
                level: .warning)
            let resumed = session.downloadTask(withResumeData: resumeData)
            attach(resumed)
            resumed.resume()
            return
        }
        resume(.failure(RemoteAssetCache.CacheError.downloadFailed(error)))
    }
}
