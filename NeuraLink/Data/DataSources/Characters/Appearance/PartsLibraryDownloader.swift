//
//  PartsLibraryDownloader.swift
//  NeuraLink
//
//  Brings the customization parts library down on first launch, the same
//  way the 3D environment arrives: fetch through RemoteAssetCache, report
//  progress to the loading screen, and release the gate when it is in.
//
//  The library is 225 MB across 68 files. It ships outside the app because
//  that is more than everything else put together, and because nothing on
//  screen needs it until the user opens customization. The pictures for the
//  cards DO ship, so the picker looks complete either way.
//
//  A missing library costs the user the extra outfits, never the app, so
//  the gate is released whether the download succeeded or gave up.
//

import Foundation

@MainActor
enum PartsLibraryDownloader {

    /// One pass per launch; the loading screen may ask more than once.
    private static var didStart = false
    private static var task: Task<Void, Never>?

    /// Attempts per file. A part is small enough that starting over costs
    /// little, and `RemoteAssetCache` already resumes within an attempt.
    private static let maxAttempts = 3

    /// Fetches everything not already on the device. Returns immediately;
    /// the loading screen watches `EnvironmentLoadState.partsReady`.
    static func start() {
        guard !didStart else { return }
        didStart = true

        let missing = PartsLibrary.shared.items.filter { !$0.isDownloaded }
        guard !missing.isEmpty else {
            EnvironmentLoadState.shared.partsDidLoad()
            return
        }
        let total = missing.reduce(Int64(0)) { $0 + ($1.asset.integrity?.size ?? 0) }
        nlLog(
            "[PartsDownload] \(missing.count) of \(PartsLibrary.shared.items.count) parts missing"
                + " (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))",
            level: .info)

        task = Task { await run(missing: missing, total: total) }
    }

    /// Drops the cached failure state so a retry can start over.
    static func reset() {
        task?.cancel()
        task = nil
        didStart = false
    }

    // MARK: - Download

    private static func run(missing: [PartsLibrary.Item], total: Int64) async {
        var completedBytes: Int64 = 0
        var done = 0
        var failed = 0

        for item in missing {
            if Task.isCancelled { break }
            let alreadyDone = completedBytes
            let onProgress: @Sendable (Int64, Int64) -> Void = { written, _ in
                Task { @MainActor in
                    EnvironmentLoadState.shared.reportPartsProgress(
                        done: done, of: missing.count,
                        downloaded: alreadyDone + max(0, written), total: total)
                }
            }
            if await fetch(item, onProgress: onProgress) == false { failed += 1 }
            completedBytes += item.asset.integrity?.size ?? 0
            done += 1
            EnvironmentLoadState.shared.reportPartsProgress(
                done: done, of: missing.count, downloaded: completedBytes, total: total)
        }

        if failed > 0 {
            nlLog(
                "[PartsDownload] \(failed) of \(missing.count) parts unavailable —"
                    + " customization will offer the rest",
                level: .warning)
        }
        EnvironmentLoadState.shared.partsDidLoad()
    }

    /// True when the file is on disk afterwards.
    private static func fetch(
        _ item: PartsLibrary.Item, onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Bool {
        for attempt in 1...maxAttempts {
            if Task.isCancelled { return false }
            do {
                _ = try await RemoteAssetCache.shared.url(for: item.asset, onProgress: onProgress)
                return true
            } catch {
                if VRMRenderer.isCancellation(error) { return false }
                nlLog(
                    "[PartsDownload] \(item.stem) attempt \(attempt)/\(maxAttempts) failed:"
                        + " \(error.localizedDescription)",
                    level: .warning)
                guard attempt < maxAttempts else { return false }
                if VRMRenderer.isConnectivityError(error) {
                    await NetworkWaiter.waitForConnectivity(timeout: 60)
                } else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
        return false
    }
}
