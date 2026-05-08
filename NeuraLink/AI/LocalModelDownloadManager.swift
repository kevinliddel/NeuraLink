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

@Observable
final class LocalModelDownloadManager: @unchecked Sendable {
    static let shared = LocalModelDownloadManager()

    // MARK: - Types

    enum DownloadState: Equatable {
        case bundled
        case notDownloaded
        case downloading(progress: Double)
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
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    enum ModelConfiguration: String, CaseIterable, Identifiable {
        case qwen2b = "Qwen3-VL 2B"
        case llama1b = "Llama-3.2 1B"
        case japaneseLlama1b = "Llama-3.2 1B (JP)"

        var id: String { rawValue }

        var repoID: String {
            switch self {
            case .qwen2b: return GGUFQwenModelAccess.repoID
            case .llama1b: return GGUFModelAccess.repoID
            case .japaneseLlama1b: return GGUFJapaneseLlamaModelAccess.repoID
            }
        }

        var estimatedSizeGB: Double {
            switch self {
            case .qwen2b: return 1.1
            case .llama1b: return 0.8
            case .japaneseLlama1b: return 0.8
            }
        }

        var description: String {
            switch self {
            case .qwen2b:
                return "High performance, stateful. Recommended for 6 GB+ devices."
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
    private(set) var selectedConfig: ModelConfiguration = {
        let sixGB: UInt64 = 6 * 1024 * 1024 * 1024
        return ProcessInfo.processInfo.physicalMemory >= sixGB ? .qwen2b : .llama1b
    }()

    private var activeTask: Task<Void, Never>?

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
    }

    func deleteDownloadedModel() {
        activeTask?.cancel()
        activeTask = nil
        switch selectedConfig {
        case .qwen2b: GGUFQwenModelAccess.clearCache()
        case .llama1b: GGUFModelAccess.clearCache()
        case .japaneseLlama1b: GGUFJapaneseLlamaModelAccess.clearCache()
        }
        state = .notDownloaded
    }

    // MARK: - Private helpers

    private func isBundled() -> Bool {
        Bundle.main.url(forResource: "chunk_0", withExtension: "mlpackage") != nil
            || Bundle.main.url(forResource: "chunk_0", withExtension: "mlmodelc") != nil
    }

    private func isDownloaded() -> Bool {
        switch selectedConfig {
        case .qwen2b: return GGUFQwenModelAccess.isDownloaded
        case .llama1b: return GGUFModelAccess.isDownloaded
        case .japaneseLlama1b: return GGUFJapaneseLlamaModelAccess.isDownloaded
        }
    }

    // MARK: - Download

    private func performDownload() async {
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

        } catch {
            guard !Task.isCancelled else {
                await MainActor.run { state = .notDownloaded }
                return
            }
            print("[ModelDownload] Failed: \(error)")
            await MainActor.run { state = .failed(error.localizedDescription) }
        }
    }
}
