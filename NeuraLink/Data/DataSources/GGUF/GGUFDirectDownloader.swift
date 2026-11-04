//
//  GGUFDirectDownloader.swift
//  NeuraLink
//
//  Downloads one GGUF straight from Hugging Face's resolve URL, with real
//  byte progress and resume. The swift-transformers snapshot this replaces
//  wires its progress through `URLSession.download(for:delegate:)`, whose
//  task delegate never gets `didWriteData` on iOS — so the Model Library bar
//  sat at 0% for the whole ~1 GB and jumped to 100% at the end. Here the
//  bytes stream through RemoteAssetCache's resumable fetch: progress as they
//  arrive, and a dropped connection, a pause or an app kill continues from
//  the partial file instead of starting over.
//
//  Files land under the same `hub/<slug>/` folder the snapshot used, so the
//  model accesses' `clearCache()` still removes them.
//
//  Integrity: the URL names a commit, not `main`, and the finished file must
//  match the size + SHA-256 pinned for that commit before it is moved into
//  place. These files come from third-party repos and are parsed by
//  llama.cpp's C loader, so a re-upload upstream must not reach the device.
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation

enum GGUFDirectDownloader {
    enum DownloadError: LocalizedError {
        case badURL
        case integrityMismatch

        var errorDescription: String? {
            switch self {
            case .badURL: return "The model's download address is invalid."
            case .integrityMismatch:
                return "The downloaded model did not match its expected checksum and was discarded. Please try again."
            }
        }
    }

    /// Fetches `filename` from `repoID` at `revision`, verifies it against
    /// `integrity`, and returns its local URL. `progress` gets 0…1, throttled
    /// to visible steps.
    static func download(
        repoID: String, revision: String, filename: String, hubSlug: String,
        integrity: RemoteAssetRegistry.AssetIntegrity,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("hub/\(hubSlug)/direct", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        // A finished file was hash-verified when it landed; one stat is
        // enough to re-accept it (same rule as RemoteAssetCache).
        if RemoteAssetCache.fileSize(at: destination) == integrity.size { return destination }
        guard let remote = remoteURL(repoID: repoID, revision: revision, filename: filename) else {
            throw DownloadError.badURL
        }
        let partURL = destination.appendingPathExtension("part")
        let throttle = ProgressThrottle(report: progress)
        try await RemoteAssetCache.fetch(
            from: remote, to: partURL, expectedSize: integrity.size,
            onProgress: { written, total in
                guard total > 0 else { return }
                throttle.update(Double(written) / Double(total))
            })
        do {
            // ~1 GB of hashing: keep it off the main actor.
            try await Task.detached(priority: .userInitiated) {
                try RemoteAssetCache.verify(fileAt: partURL, against: integrity)
            }.value
        } catch {
            // A bad file must not survive as resume state for the next try.
            try? FileManager.default.removeItem(at: partURL)
            nlLog("[GGUFDirectDownloader] \(filename) failed verification: \(error)", level: .error)
            throw DownloadError.integrityMismatch
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? (destination as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        progress(1)
        return destination
    }

    /// `resolve/<commit>` rather than `resolve/main`, so the bytes are the
    /// ones the pinned hash was taken from.
    static func remoteURL(repoID: String, revision: String, filename: String) -> URL? {
        URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(filename)")
    }
}

/// Passes progress on only when it has moved by half a percent, so a 1 GB
/// download doesn't redraw the bar fifteen thousand times. `nonisolated`:
/// it is fed from the download's delegate queue and guards itself with `lock`.
private nonisolated final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let report: @Sendable (Double) -> Void

    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func update(_ fraction: Double) {
        let send = lock.withLock { () -> Bool in
            guard fraction - last >= 0.005 || fraction >= 1 else { return false }
            last = fraction
            return true
        }
        if send { report(min(max(fraction, 0), 1)) }
    }
}
