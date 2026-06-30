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
        case llama1b = "Llama-3.2 1B"
        case llmJp3 = "LLM-jp 3 (1.8B)"

        var id: String { rawValue }

        var repoID: String {
            switch self {
            case .llama1b: return GGUFModelAccess.repoID
            case .llmJp3: return GGUFLLMjp3ModelAccess.repoID
            }
        }

        var estimatedSizeGB: Double {
            switch self {
            // Q4_K_M (~0.81 GB) — Q8_0 (1.32) was too big for 4 GB (jetsam).
            case .llama1b: return 0.81
            // LLM-jp-3 1.8B instruct, Q3_K_M — see quantizationLabel.
            case .llmJp3: return 0.96
            }
        }

        var quantizationLabel: String {
            switch self {
            case .llama1b:
                // Q4_K_M (~0.81 GB): fits resident on 4 GB (Q8_0 1.32 jetsam'd).
                // See GGUFModelAccess.swift.
                return "Q4_K_M"
            case .llmJp3:
                // LLM-jp-3 1.8B instruct, Q3_K_M (~0.96 GB): sized to stay
                // resident on the 4 GB tier (loaded non-mmap; gemma 2B streamed
                // from flash and even its 1.30 GB IQ3_M crashed). See
                // GGUFLLMjp3ModelAccess.swift.
                return "Q3_K_M"
            }
        }

        var description: String {
            switch self {
            case .llama1b:
                return "Fast and highly memory-efficient, optimized for everyday use."
            case .llmJp3:
                return "Japanese-native LLM, tuned for fast and memory-efficient performance."
            }
        }
    }

    // MARK: - State

    private static let configKey = "LocalModelSelectedConfig"

    private(set) var state: DownloadState = .notDownloaded
    private(set) var selectedConfig: ModelConfiguration =
        LocalModelDownloadManager.defaultConfigForCurrentDevice()

    /// Default model on first launch. All devices default to the memory-safe
    /// Llama-3.2 1B; Qwen 2B and the Japanese model (LLM-jp-3) are opt-in via
    /// Settings. (Qwen 3B / 7B were removed.)
    static func defaultConfigForCurrentDevice() -> ModelConfiguration {
        .llama1b
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
    /// selected model, also cancels any in-progress download, drops the
    /// engine's mmap'd file handle, and resets `state` to `.notDownloaded`.
    ///
    /// The `LocalLLMManager.unload()` call is critical for disk reclaim.
    /// Every engine `mmap`s its GGUF weights via llama.cpp. iOS only
    /// reclaims the bytes when the LAST process unmaps the file, so a
    /// delete without unload leaves the kernel holding the file open
    /// (the Documents & Data figure stays at the pre-delete value until
    /// the next app launch).
    func deleteModel(_ config: ModelConfiguration) {
        let isSelected = (config == selectedConfig)
        if isSelected {
            activeTask?.cancel()
            activeTask = nil
            LocalLLMManager.shared.unload()
        }
        switch config {
        case .llama1b: GGUFModelAccess.clearCache()
        case .llmJp3: GGUFLLMjp3ModelAccess.clearCache()
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
        case .llama1b: url = GGUFModelAccess.modelURL()
        case .llmJp3: url = GGUFLLMjp3ModelAccess.modelURL()
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
        case .llama1b: return GGUFModelAccess.isDownloaded
        case .llmJp3: return GGUFLLMjp3ModelAccess.isDownloaded
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
            case .llama1b:
                try await GGUFLlamaDownloader.download(api: api) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading = self?.state else { return }
                        // Model fills 0–80% of the bar; the bundled voice model
                        // (downloadVoiceAssets) fills the 80–100% tail.
                        self?.state = .downloading(progress: progress * 0.8)
                    }
                }
            case .llmJp3:
                try await GGUFLLMjp3Downloader.download(api: api) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard case .downloading = self?.state else { return }
                        // Model fills 0–80% of the bar; the bundled voice model
                        // (downloadVoiceAssets) fills the 80–100% tail.
                        self?.state = .downloading(progress: progress * 0.8)
                    }
                }
            }

            guard !Task.isCancelled else { return }

            // Bundle the matching voice model so the user never has to fetch it
            // separately in Persona settings. Best-effort — see the method doc.
            await downloadVoiceAssets(for: config)
            // downloadVoiceAssets swallows its errors as best-effort, so an
            // in-tail cancel/pause wouldn't surface as a throw — honour it here
            // rather than overriding the user's action by publishing `.ready`.
            guard !Task.isCancelled else {
                endBackgroundTask()
                return
            }

            await MainActor.run { state = .downloading(progress: 1.0) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run { state = .ready }
            nlLog("[ModelDownload] Ready: \(config.rawValue)", level: .info)
            endBackgroundTask()

        } catch {
            guard !Task.isCancelled else {
                await MainActor.run { state = .notDownloaded }
                endBackgroundTask()
                return
            }
            nlLog("[ModelDownload] Failed: \(error)", level: .error)
            await MainActor.run { state = .failed(error.localizedDescription) }
            endBackgroundTask()
        }
    }

    /// Best-effort download of the voice-model assets paired with `config`, so
    /// the user never has to fetch them separately in Persona settings:
    /// VoiceVox (Open JTalk dict + default speaker pack) for the JP model, and
    /// OpenVoice (MeloTTS + tone-color converter, optional prosody BERT) for
    /// the English models. A failure here does NOT fail the model download —
    /// the LLM is already on disk and TTS falls back to the iOS system voice.
    /// `RemoteAssetCache` is idempotent, so already-cached assets are skipped.
    private func downloadVoiceAssets(for config: ModelConfiguration) async {
        do {
            switch config {
            case .llmJp3:
                await setVoiceProgress(0.85)
                // Open JTalk dictionary: many small files — fan out in parallel.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for name in RemoteAssetRegistry.jtalkDictFilenames {
                        group.addTask {
                            _ = try await RemoteAssetCache.shared.url(for: .jtalkDictFile(name))
                        }
                    }
                    try await group.waitForAll()
                }
                await setVoiceProgress(0.95)
                // Default speaker pack; other personas' speakers lazy-download
                // through the same cache on first use.
                let speaker = VoiceVoxSpeaker.map(VoiceVoxSpeaker.defaultSpeakerID).filenameID
                _ = try await RemoteAssetCache.shared.url(for: .voicevoxSpeaker(speaker))
            case .llama1b:
                await setVoiceProgress(0.85)
                _ = try await OpenVoiceModelAccess.meloModel()
                await setVoiceProgress(0.92)
                _ = try await OpenVoiceModelAccess.converterModel()
                await setVoiceProgress(0.97)
                _ = await OpenVoiceModelAccess.bertModel()  // optional; nil on failure
            }
            nlLog("[ModelDownload] Voice assets ready for \(config.rawValue)", level: .info)
        } catch {
            nlLog(
                "[ModelDownload] Voice assets failed for \(config.rawValue) (best-effort): \(error)",
                level: .warning)
        }
    }

    /// Updates the download bar within the voice-bundle tail. No-op if the
    /// download was cancelled or already finished.
    private func setVoiceProgress(_ progress: Double) async {
        await MainActor.run {
            guard case .downloading = self.state else { return }
            self.state = .downloading(progress: progress)
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
