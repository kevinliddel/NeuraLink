//
//  MotionModelAccess.swift
//  NeuraLink
//
//  The six motion model files as remote assets: pinned in
//  RemoteAssetRegistry, fetched and verified by RemoteAssetCache into
//  `<App Support>/hf-assets/motion/ardy-mini/`, removed from the same card
//  that downloaded them. A hand-copied folder in Caches (the bench's) is
//  accepted as a fallback for development. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Observation

enum MotionModelAccess {
    static let assets: [RemoteAssetRegistry] = [
        .motionManifest, .motionTextEncoder, .motionDenoiser, .motionDecoder, .motionTokenizer, .motionTokenizerConfig
    ]

    /// Bytes of the whole download.
    static var totalBytes: Int64 { assets.compactMap { $0.integrity?.size }.reduce(0, +) }

    /// True when every file has been downloaded and verified.
    nonisolated static var isDownloaded: Bool { assets.allSatisfy(\.isCachedLocally) }

    /// The downloaded files, when all are there.
    static func downloadedFiles() async -> ARDYModelFiles? {
        let cache = RemoteAssetCache.shared
        guard let manifest = await cache.localURLIfAvailable(for: .motionManifest),
              let encoder = await cache.localURLIfAvailable(for: .motionTextEncoder),
              let denoiser = await cache.localURLIfAvailable(for: .motionDenoiser),
              let decoder = await cache.localURLIfAvailable(for: .motionDecoder),
              let tokenizer = await cache.localURLIfAvailable(for: .motionTokenizer),
              let config = await cache.localURLIfAvailable(for: .motionTokenizerConfig)
        else { return nil }
        return ARDYModelFiles(manifest: manifest, textEncoder: encoder, denoiser: denoiser, decoder: decoder, tokenizer: tokenizer, tokenizerConfig: config)
    }

    /// Downloads whatever is missing, one file after another; `progress`
    /// gets the bytes done over the total across all six.
    static func download(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = totalBytes
        var done: Int64 = 0
        for asset in assets {
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
                    Task { @MainActor in self?.phase = .downloading(fraction: fraction) }
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
