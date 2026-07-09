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

import Foundation

actor RemoteAssetCache {
    static let shared = RemoteAssetCache()

    enum CacheError: Error {
        case assetNotFound
        case downloadFailed(Error)
        case httpStatus(Int)
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
            resolved[asset] = onDisk
            return onDisk
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

        if let onProgress {
            return try await downloadWithProgress(
                from: remoteURL, to: target, onProgress: onProgress)
        }

        do {
            let (downloadedTempURL, response) = try await URLSession.shared.download(
                from: remoteURL)
            if let http = response as? HTTPURLResponse,
                !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: downloadedTempURL)
                throw CacheError.httpStatus(http.statusCode)
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: downloadedTempURL, to: target)
            return target
        } catch let err as CacheError {
            throw err
        } catch {
            throw CacheError.downloadFailed(error)
        }
    }

    /// Downloads with byte-progress via a dedicated delegate-backed session.
    /// The delegate moves the temp file into place (it's deleted the moment its
    /// callback returns) and resumes the continuation, so this bridges the
    /// classic download-task API into async/await. Cancelling the awaiting task
    /// cancels the underlying `URLSessionDownloadTask`.
    private static func downloadWithProgress(
        from remoteURL: URL,
        to target: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let delegate = DownloadProgressDelegate(target: target, onProgress: onProgress)
        let session = URLSession(
            configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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
/// byte-progress. On completion it moves the temp file into `target` (the
/// system deletes it once `didFinishDownloadingTo` returns) and resumes the
/// continuation exactly once. Progress is throttled to ~every 256 KB so a
/// multi-hundred-MB fetch doesn't flood the main actor.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable {
    private let target: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var lastReported: Int64 = 0
    private var continuation: CheckedContinuation<URL, Error>?
    private var didResume = false
    private var task: URLSessionDownloadTask?

    init(target: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.target = target
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
        lock.unlock()
    }

    func cancel() {
        lock.lock()
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
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)
            resume(.success(target))
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
        if let error {
            resume(.failure(RemoteAssetCache.CacheError.downloadFailed(error)))
        }
    }
}
