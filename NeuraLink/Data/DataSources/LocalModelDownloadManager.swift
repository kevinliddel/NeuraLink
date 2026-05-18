//
//  LocalModelDownloadManager.swift
//  NeuraLink
//
//  Manages the download state machine for local SLMs.
//  Model-specific download strategies live in QwenModelDownloader and LlamaModelDownloader.
//  URL/path resolution is delegated to QwenModelAccess and LlamaModelAccess.
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation
import Hub
import UIKit

@Observable
final class LocalModelDownloadManager: @unchecked Sendable {
    static let shared = LocalModelDownloadManager()

    // MARK: - Types

    enum DownloadState: Equatable {
        case bundled
        case notDownloaded
        case downloading(progress: Double)
        case paused(progress: Double)
        case ready
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.bundled, .bundled), (.notDownloaded, .notDownloaded), (.ready, .ready):
                return true
            case (.downloading(let a), .downloading(let b)):
                return abs(a - b) < 0.001
            case (.paused(let a), .paused(let b)):
                return abs(a - b) < 0.001
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    enum ModelConfiguration: String, CaseIterable, Identifiable {
        case qwen2b = "Qwen3-VL 2B"
        case qwen3b = "Qwen2.5 3B"
        case qwen7b = "Qwen2.5 7B"
        case llama1b = "Llama-3.2 1B"
        case japaneseLlama1b = "Llama-3.2 1B (JP)"

        var id: String { rawValue }

        var repoID: String {
            switch self {
            case .qwen2b: return GGUFQwenModelAccess.repoID
            case .qwen3b: return GGUFQwen3BModelAccess.repoID
            case .qwen7b: return GGUFQwen7BModelAccess.repoID
            case .llama1b: return GGUFModelAccess.repoID
            case .japaneseLlama1b: return GGUFJapaneseLlamaModelAccess.repoID
            }
        }

        var estimatedSizeGB: Double {
            switch self {
            case .qwen2b: return 1.1
            case .qwen3b: return 1.93
            case .qwen7b: return 4.68
            case .llama1b: return 0.8
            case .japaneseLlama1b: return 0.8
            }
        }

        var quantizationLabel: String {
            switch self {
            case .qwen2b, .qwen3b, .qwen7b, .llama1b, .japaneseLlama1b:
                return "Q4_K_M"
            }
        }

        var description: String {
            switch self {
            case .qwen2b:
                return "High performance, stateful. Recommended for 6 GB+ devices."
            case .qwen3b:
                return "Strong reasoning. Recommended for iPhone 14 / 15 base (6 GB RAM)."
            case .qwen7b:
                return "Top quality. Recommended for iPhone 15 Pro+ / 16 family (8 GB RAM)."
            case .llama1b:
                return "Memory efficient. Recommended for iPhone 11, 12 or 13 (4 GB RAM)."
            case .japaneseLlama1b:
                return "Japanese-oriented Llama-3.2 1B. Best for Japanese conversation on 4 GB+ devices."
            }
        }
    }

    // MARK: - State

    private static let configKey = "LocalModelSelectedConfig"

    private(set) var state: DownloadState = .notDownloaded
    private(set) var selectedConfig: ModelConfiguration = LocalModelDownloadManager.defaultConfigForCurrentDevice()

    /// Buckets `physicalMemory` into the best default tier for the device.
    /// iPhone 11/12/13 = 4 GB → llama1b. iPhone 14/15 base = 6 GB → qwen3b.
    /// iPhone 15 Pro+ / 16 family = 8 GB → qwen7b.
    static func defaultConfigForCurrentDevice() -> ModelConfiguration {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb >= 7.0 { return .qwen7b }
        if gb >= 5.0 { return .qwen3b }
        return .llama1b
    }

    private var activeTask: Task<Void, Never>?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    var isAvailable: Bool {
        switch state {
        case .bundled, .ready: return true
        default: return false
        }
    }

    // MARK: - Init

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.configKey),
            let config = ModelConfiguration(rawValue: saved) {
            selectedConfig = config
        }
        refreshState()
    }

    // MARK: - Configuration

    func selectConfig(_ config: ModelConfiguration) {
        guard state == .notDownloaded || state == .ready || state.isFailed else { return }
        selectedConfig = config
        UserDefaults.standard.set(config.rawValue, forKey: Self.configKey)
        refreshState()
    }

    // MARK: - State resolution

    func refreshState() {
        if isBundled() {
            state = .bundled
        } else if isDownloaded() {
            state = .ready
        } else {
            state = .notDownloaded
        }
    }

    // MARK: - Download lifecycle

    func startDownload() {
        guard case .notDownloaded = state else { return }
        activeTask?.cancel()
        activeTask = Task { await performDownload() }
    }

    func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        state = .notDownloaded
        endBackgroundTask()
    }

    func pauseDownload() {
        guard case .downloading(let progress) = state else { return }
        activeTask?.cancel()
        activeTask = nil
        state = .paused(progress: progress)
        endBackgroundTask()
    }

    func resumeDownload() {
        guard case .paused = state else { return }
        state = .notDownloaded
        startDownload()
    }

    func deleteDownloadedModel() {
        deleteModel(selectedConfig)
    }

    /// Wipes the on-disk cache for `config`. If `config` is the currently
    /// selected model, also cancels any in-progress download and resets
    /// `state` to `.notDownloaded`.
    func deleteModel(_ config: ModelConfiguration) {
        let isSelected = (config == selectedConfig)
        if isSelected {
            activeTask?.cancel()
            activeTask = nil
        }
        switch config {
        case .qwen2b: GGUFQwenModelAccess.clearCache()
        case .qwen3b: GGUFQwen3BModelAccess.clearCache()
        case .qwen7b: GGUFQwen7BModelAccess.clearCache()
        case .llama1b: GGUFModelAccess.clearCache()
        case .japaneseLlama1b: GGUFJapaneseLlamaModelAccess.clearCache()
        }
        if isSelected {
            state = .notDownloaded
            endBackgroundTask()
        }
    }

    /// Wipes every model's cache. Useful when accumulated GGUF caches
    /// (each 0.8–4.7 GB) push the app's data footprint into double digits.
    func deleteAllModels() {
        for config in ModelConfiguration.allCases {
            deleteModel(config)
        }
    }

    /// Combined on-disk cache size across every downloadable model.
    var totalCacheBytes: Int64 {
        ModelConfiguration.allCases.reduce(0) { $0 + diskUsageBytes(for: $1) }
    }

    func diskUsageBytes(for config: ModelConfiguration) -> Int64 {
        let url: URL?
        switch config {
        case .qwen2b: url = GGUFQwenModelAccess.modelURL()
        case .qwen3b: url = GGUFQwen3BModelAccess.modelURL()
        case .qwen7b: url = GGUFQwen7BModelAccess.modelURL()
        case .llama1b: url = GGUFModelAccess.modelURL()
        case .japaneseLlama1b: url = GGUFJapaneseLlamaModelAccess.modelURL()
        }
        
        guard let fileURL = url else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.size] as? Int64 ?? 0
    }

    // MARK: - Private helpers

    func downloadState(for config: ModelConfiguration) -> DownloadState {
        if config == selectedConfig {
            return state
        }
        if isBundled() {
            return .bundled
        }
        return isDownloaded(config) ? .ready : .notDownloaded
    }

    private func isBundled() -> Bool {
        Bundle.main.url(forResource: "chunk_0", withExtension: "mlpackage") != nil
            || Bundle.main.url(forResource: "chunk_0", withExtension: "mlmodelc") != nil
    }

    private func isDownloaded() -> Bool {
        isDownloaded(selectedConfig)
    }

    private func isDownloaded(_ config: ModelConfiguration) -> Bool {
        switch config {
        case .qwen2b: return GGUFQwenModelAccess.isDownloaded
        case .qwen3b: return GGUFQwen3BModelAccess.isDownloaded
        case .qwen7b: return GGUFQwen7BModelAccess.isDownloaded
        case .llama1b: return GGUFModelAccess.isDownloaded
        case .japaneseLlama1b: return GGUFJapaneseLlamaModelAccess.isDownloaded
        }
    }

    // MARK: - Download

    private func performDownload() async {
        await beginBackgroundTask()
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let api = HubApi(downloadBase: appSupport)
        let config = selectedConfig

        do {
            await MainActor.run { state = .downloading(progress: 0.0) }

            switch config {
            case .qwen2b:
                try await GGUFQwenDownloader.download(api: api) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading = self?.state else { return }
                        self?.state = .downloading(progress: progress)
                    }
                }
            case .qwen3b:
                try await GGUFQwen3BDownloader.download(api: api) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading = self?.state else { return }
                        self?.state = .downloading(progress: progress)
                    }
                }
            case .qwen7b:
                try await GGUFQwen7BDownloader.download(api: api) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading = self?.state else { return }
                        self?.state = .downloading(progress: progress)
                    }
                }
            case .llama1b:
                try await GGUFLlamaDownloader.download(api: api) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading = self?.state else { return }
                        self?.state = .downloading(progress: progress)
                    }
                }
            case .japaneseLlama1b:
                try await GGUFJapaneseLlamaDownloader.download(api: api) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading = self?.state else { return }
                        self?.state = .downloading(progress: progress)
                    }
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { state = .downloading(progress: 1.0) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { state = .ready }
            print("[ModelDownload] Ready: \(config.rawValue)")
            endBackgroundTask()

        } catch {
            guard !Task.isCancelled else {
                await MainActor.run { state = .notDownloaded }
                endBackgroundTask()
                return
            }
            print("[ModelDownload] Failed: \(error)")
            await MainActor.run { state = .failed(error.localizedDescription) }
            endBackgroundTask()
        }
    }

    @MainActor
    private func beginBackgroundTask() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "LocalModelDownload") {
            Task { @MainActor [weak self] in
                self?.backgroundTaskId = .invalid
            }
        }
    }

    private func endBackgroundTask() {
        let id = backgroundTaskId
        guard id != .invalid else { return }
        backgroundTaskId = .invalid
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(id)
        }
    }
}
