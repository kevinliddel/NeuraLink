//
//  PartsLibraryDownloader.swift
//  NeuraLink
//
//  Brings the customization parts library down in the background: fetch
//  through RemoteAssetCache, report progress to the loading screen while it
//  is up, never hold the scene for it. The library is 364 MB across 119
//  files — more than everything else put together — and nothing on screen
//  needs it until the user opens customization; the pictures for the cards
//  DO ship, so the picker looks complete either way, and a part that has
//  not arrived is fetched when its tile is tapped.
//
//  Each file resumes from its partial (RemoteAssetCache.fetch), so a slow
//  link makes progress across attempts and launches instead of starting
//  the same outfit over. A file the server does not have (4xx) is not
//  asked for again for `unavailableCooldown`.
//

import Foundation

@MainActor
enum PartsLibraryDownloader {

    /// One pass per launch; the loading screen may ask more than once.
    private static var didStart = false
    private static var task: Task<Void, Never>?

    /// Attempts per file and launch; each one continues the partial.
    private static let maxAttempts = 3

    /// A 4xx means the dataset simply does not have the file — a part
    /// pinned before its upload landed, or taken down. Asking again on
    /// every launch gains nothing, so the stem rests this long.
    static let unavailableCooldown: TimeInterval = 6 * 60 * 60
    private static let cooldownKey = "PartsLibraryDownloader.unavailableUntil"

    /// Fetches everything not already on the device, in the background.
    /// Returns immediately; the loading screen shows progress while it is
    /// up but does not wait for it.
    static func start() {
        guard !didStart else { return }
        didStart = true

        let now = Date()
        let resting = cooldowns()
        let missing = PartsLibrary.shared.items.filter { item in
            guard !item.isDownloaded else { return false }
            guard let until = resting[item.stem] else { return true }
            return until <= now
        }
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
                if isPermanentFailure(error) {
                    markUnavailable(item.stem)
                    return false
                }
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

    // MARK: - Availability memo

    /// A 4xx is the server's answer, not the network's: retrying it does
    /// not help. Transport errors and 5xx keep their attempts.
    nonisolated static func isPermanentFailure(_ error: Error) -> Bool {
        if case RemoteAssetCache.CacheError.httpStatus(let code) = error {
            return (400..<500).contains(code)
        }
        return false
    }

    private static func cooldowns() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: cooldownKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func markUnavailable(_ stem: String) {
        var raw = UserDefaults.standard.dictionary(forKey: cooldownKey) as? [String: Double] ?? [:]
        raw[stem] = Date().addingTimeInterval(unavailableCooldown).timeIntervalSince1970
        UserDefaults.standard.set(raw, forKey: cooldownKey)
    }
}
