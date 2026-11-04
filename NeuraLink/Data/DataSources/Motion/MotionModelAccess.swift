//
//  MotionModelAccess.swift
//  NeuraLink
//
//  The nine motion model files as remote assets: pinned in
//  RemoteAssetRegistry, fetched and verified by RemoteAssetCache into
//  `<App Support>/hf-assets/motion/ardy-mini-external/`, removed from the
//  same card that downloaded them. Each graph's weights are a sidecar the
//  graph names, so the two must sit together, as they do there. A
//  hand-copied folder in Caches (the bench's) is accepted as a fallback for
//  development. The download folders of the two earlier families are
//  deleted once, at launch. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Observation

enum MotionModelAccess {
    static let assets: [RemoteAssetRegistry] = [
        .motionManifest, .motionTextEncoder, .motionTextEncoderWeights, .motionDenoiser, .motionDenoiserWeights,
        .motionDecoder, .motionDecoderWeights, .motionTokenizer, .motionTokenizerConfig
    ]

    /// Bytes of the whole download.
    static var totalBytes: Int64 { assets.compactMap { $0.integrity?.size }.reduce(0, +) }

    /// True when every file is on disk at its pinned size (the download
    /// verified each one before moving it there; this is one stat apiece).
    nonisolated static var isDownloaded: Bool { assets.allSatisfy(isOnDiskAtPinnedSize) }

    nonisolated static func isOnDiskAtPinnedSize(_ asset: RemoteAssetRegistry) -> Bool {
        guard asset.isCachedLocally else { return false }
        guard let expected = asset.integrity?.size,
              let support = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return true }
        let file = support.appendingPathComponent("hf-assets").appendingPathComponent(asset.pathInRepo)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        return size?.int64Value == expected
    }

    /// The downloaded files, when all are there.
    static func downloadedFiles() async -> ARDYModelFiles? {
        let cache = RemoteAssetCache.shared
        guard let manifest = await cache.localURLIfAvailable(for: .motionManifest),
              let encoder = await cache.localURLIfAvailable(for: .motionTextEncoder),
              let denoiser = await cache.localURLIfAvailable(for: .motionDenoiser),
              let decoder = await cache.localURLIfAvailable(for: .motionDecoder),
              let tokenizer = await cache.localURLIfAvailable(for: .motionTokenizer),
              let config = await cache.localURLIfAvailable(for: .motionTokenizerConfig),
              // The sidecars too, size-checked like the rest: the runtime finds
              // them by name beside their graphs.
              await cache.localURLIfAvailable(for: .motionTextEncoderWeights) != nil,
              await cache.localURLIfAvailable(for: .motionDenoiserWeights) != nil,
              await cache.localURLIfAvailable(for: .motionDecoderWeights) != nil
        else { return nil }
        let files = ARDYModelFiles(
            manifest: manifest, textEncoder: encoder, denoiser: denoiser, decoder: decoder, tokenizer: tokenizer,
            tokenizerConfig: config)
        // The sidecars are found by name beside their graphs; the cache put
        // them there, but a missing one must not reach the runtime.
        return files.isComplete ? files : nil
    }

    /// Downloads whatever is missing, one file after another; `progress`
    /// gets the bytes done over the total across all nine.
    static func download(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = totalBytes
        var done: Int64 = 0
        for asset in assets {
            try Task.checkCancellation()
            let size = asset.integrity?.size ?? 0
            let base = done
            _ = try await RemoteAssetCache.shared.url(for: asset) { received, _ in
                progress(base + min(received, size), total)
            }
            done += size
            progress(done, total)
        }
    }

    static func remove() async {
        for asset in assets { await RemoteAssetCache.shared.remove(asset) }
    }

    /// The download folders of the earlier families, relative to the asset
    /// cache's base: the single-file fp32 graphs (775 MB, until 2026-11-02)
    /// and the float16 graphs (371 MB, the same day).
    static let supersededFolders = ["motion/ardy-mini", "motion/ardy-mini-fp16"]

    /// Deletes an earlier family's download if a phone still has it, so it
    /// does not linger beside the current one. Safe to call every launch:
    /// one stat per folder.
    nonisolated static func removeSupersededDownloads() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return }
        for superseded in supersededFolders {
            let folder = support.appendingPathComponent("hf-assets").appendingPathComponent(superseded, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                nlLog("[MotionModel] removed the superseded download \(superseded)", level: .info)
            } catch {
                nlLog("[MotionModel] could not remove the superseded download \(superseded): \(error)", level: .warning)
            }
        }
    }
}

/// What the Settings card shows.
@Observable
final class MotionModelDownloadState {
    static let shared = MotionModelDownloadState()

    enum Phase: Equatable {
        case missing
        case downloading(fraction: Double)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = MotionModelAccess.isDownloaded ? .ready : .missing
    private var task: Task<Void, Never>?

    private init() {}

    var isBusy: Bool {
        if case .downloading = phase { return true }
        return false
    }

    func refresh() {
        guard !isBusy else { return }
        phase = MotionModelAccess.isDownloaded ? .ready : .missing
    }

    func download() {
        guard !isBusy else { return }
        phase = .downloading(fraction: 0)
        task = Task { [weak self] in
            do {
                try await MotionModelAccess.download { done, total in
                    let fraction = total > 0 ? Double(done) / Double(total) : 0
                    // Queued updates can land after the download ended; they
                    // must not turn a finished card back into a busy one.
                    Task { @MainActor in
                        guard let self, case .downloading = self.phase else { return }
                        self.phase = .downloading(fraction: fraction)
                    }
                }
                self?.phase = .ready
                nlLog("[MotionModel] downloaded and verified", level: .info)
            } catch is CancellationError {
                self?.phase = MotionModelAccess.isDownloaded ? .ready : .missing
            } catch {
                self?.phase = .failed(Self.message(for: error))
                nlLog("[MotionModel] download failed: \(error)", level: .warning)
            }
            MotionStreamCoordinator.shared.refreshAvailability()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        // The cache downloads each file in a task of its own, which
        // cancelling ours does not reach; invalidating cancels the file in
        // flight (the same call the loading screen's Retry uses). Only the
        // motion files: no other feature shares them.
        Task {
            for asset in MotionModelAccess.assets { await RemoteAssetCache.shared.invalidate(asset) }
        }
    }

    /// What the card says: a 404 means the files are not in the dataset yet,
    /// which is a publishing step, not a phone problem.
    static func message(for error: Error) -> String {
        if case RemoteAssetCache.CacheError.httpStatus(let code) = error {
            switch code {
            case 404: return "Not published yet: the model files are not in the asset dataset."
            case 400..<500: return "The download was refused (HTTP \(code))."
            default: return "The server failed (HTTP \(code)). Try again later."
            }
        }
        if (error as? URLError) != nil { return "No connection. Try again when online." }
        return error.localizedDescription
    }

    func remove() {
        cancel()
        Task { [weak self] in
            MotionStreamCoordinator.shared.unload()
            await MotionModelAccess.remove()
            self?.phase = .missing
            MotionStreamCoordinator.shared.refreshAvailability()
            nlLog("[MotionModel] removed", level: .info)
        }
    }
}
