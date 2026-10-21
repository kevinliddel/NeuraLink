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
//  Created by Dedicatus on 21/10/2026.
//

import Foundation

enum GGUFDirectDownloader {
    enum DownloadError: LocalizedError {
        case badURL
        case notAGGUF

        var errorDescription: String? {
            switch self {
            case .badURL: return "The model's download address is invalid."
            case .notAGGUF: return "The downloaded file is not a GGUF model."
            }
        }
    }

    /// Fetches `filename` from `repoID` and returns its local URL. `progress`
    /// gets 0…1, throttled to visible steps.
    static func download(
        repoID: String, filename: String, hubSlug: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("hub/\(hubSlug)/direct", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        if isGGUF(destination) { return destination }
        guard let remote = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename)") else {
            throw DownloadError.badURL
        }
        let partURL = destination.appendingPathExtension("part")
        let throttle = ProgressThrottle(report: progress)
        try await RemoteAssetCache.fetch(
            from: remote, to: partURL, expectedSize: nil,
            onProgress: { written, total in
                guard total > 0 else { return }
                throttle.update(Double(written) / Double(total))
            })
        guard isGGUF(partURL) else {
            try? FileManager.default.removeItem(at: partURL)
            throw DownloadError.notAGGUF
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
        try? (destination as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        progress(1)
        return destination
    }

    /// A GGUF file starts with the ASCII magic "GGUF".
    static func isGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}

/// Passes progress on only when it has moved by half a percent, so a 1 GB
/// download doesn't redraw the bar fifteen thousand times.
private final class ProgressThrottle: @unchecked Sendable {
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
