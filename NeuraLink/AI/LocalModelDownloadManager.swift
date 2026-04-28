//
//  LocalModelDownloadManager.swift
//  NeuraLink
//
//  Tracks whether the Qwen3-VL 2B model is bundled, already downloaded to
//  Application Support, or needs to be fetched from HuggingFace.
//  The LLM engines call urlForChunk(_:) / urlForEmbed() to resolve model files
//  without caring whether they live in the bundle or in the downloaded cache.
//

import CoreML
import Foundation
import Hub

@Observable
final class LocalModelDownloadManager: @unchecked Sendable {
    static let shared = LocalModelDownloadManager()

    enum DownloadState: Equatable {
        case bundled                      // Files are in the app bundle — no download needed
        case notDownloaded                // Neither bundled nor in Application Support
        case downloading(progress: Double)
        case ready                        // Compiled files are in Application Support
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.bundled, .bundled), (.notDownloaded, .notDownloaded), (.ready, .ready):
                return true
            case let (.downloading(a), .downloading(b)):
                return abs(a - b) < 0.001
            case let (.failed(a), .failed(b)):
                return a == b
            default:
                return false
            }
        }
    }

    enum ModelConfiguration: String, CaseIterable, Identifiable {
        case qwen2b = "Qwen3-VL 2B"
        case llama1b = "Llama-3.2 1B"
        
        var id: String { self.rawValue }
        
        var repoID: String {
            switch self {
            case .qwen2b: return "mlboydaisuke/qwen3-vl-2b-stateful-coreml"
            case .llama1b: return "smpanaro/Llama-3.2-1B-Instruct-CoreML"
            }
        }
        
        var estimatedSizeGB: Double {
            switch self {
            case .qwen2b: return 2.7
            case .llama1b: return 0.8
            }
        }
        
        var description: String {
            switch self {
            case .qwen2b: return "High performance, stateful. Recommended for 6GB+ devices."
            case .llama1b: return "Memory efficient. Recommended for iPhone 11/12/13 (4GB RAM)."
            }
        }
    }

    private(set) var state: DownloadState = .notDownloaded
    var selectedConfig: ModelConfiguration = ProcessInfo.processInfo.physicalMemory >= 6 * 1024 * 1024 * 1024 ? .qwen2b : .llama1b
    private var activeTask: Task<Void, Never>?

    /// Where compiled .mlmodelc and embed_weight.bin live after download.
    var compiledDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuraLink/LocalModels", isDirectory: true)
            .appendingPathComponent(selectedConfig == .qwen2b ? "qwen3-vl-2b" : "llama-3.2-1b", isDirectory: true)
    }

    var isAvailable: Bool {
        switch state {
        case .bundled, .ready: return true
        default: return false
        }
    }

    private init() { refreshState() }

    func selectConfig(_ config: ModelConfiguration) {
        guard state == .notDownloaded || state == .ready || state.isFailed else { return }
        selectedConfig = config
        refreshState()
    }

    // MARK: - State resolution

    func refreshState() {
        if isBundled() {
            state = .bundled
        } else if isCompiledCacheComplete() {
            state = .ready
        } else {
            state = .notDownloaded
        }
    }

    private func isBundled() -> Bool {
        Bundle.main.url(forResource: "chunk_0", withExtension: "mlmodelc") != nil
    }

    private func isCompiledCacheComplete() -> Bool {
        let dir = compiledDir
        if selectedConfig == .qwen2b {
            let chunkNames = (0..<4).map { "chunk_\($0)" } + ["chunk_head"]
            let chunksOK = chunkNames.allSatisfy {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).mlmodelc").path)
            }
            let embedOK = FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("embed_weight.bin").path)
            return chunksOK && embedOK
        } else {
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.mlmodelc").path)
        }
    }

    // MARK: - URL resolution (called by engine loaders)

    /// Returns the .mlmodelc URL for a given chunk name, or nil if unavailable.
    func urlForChunk(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        
        let actualName = (selectedConfig == .llama1b && name == "LocalChatModel_Int4") 
            ? "model" 
            : name
            
        let cached = compiledDir.appendingPathComponent("\(actualName).mlmodelc")
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    /// Returns the embed_weight.bin URL, or nil if unavailable.
    func urlForEmbed() -> URL? {
        if let url = Bundle.main.url(forResource: "embed_weight", withExtension: "bin") {
            return url
        }
        let cached = compiledDir.appendingPathComponent("embed_weight.bin")
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
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
        try? FileManager.default.removeItem(at: compiledDir)
        state = .notDownloaded
    }

    // MARK: - Download + compile

    private enum DownloadError: LocalizedError {
        case repositoryNotFound
        case chunkMissing(String)

        var errorDescription: String? {
            switch self {
            case .repositoryNotFound:
                return "Repository was not found on Hugging Face. Make sure the repo is public."
            case .chunkMissing(let name):
                return "'\(name)' not found in the repository."
            }
        }
    }

    private func performDownload() async {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let api = HubApi(downloadBase: appSupport)
        let repo = Hub.Repo(id: selectedConfig.repoID)
        let destDir = compiledDir

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            await MainActor.run { state = .downloading(progress: 0.0) }

            let snapshotDir = try await api.snapshot(from: repo) { progress in
                Task { @MainActor in
                    guard case .downloading = self.state else { return }
                    self.state = .downloading(progress: progress.fractionCompleted * 0.5)
                }
            }

            guard !Task.isCancelled else { return }
            let repoRoot = snapshotDir
            
            if selectedConfig == .qwen2b {
                let sub = "qwen3_vl_2b_stateful_chunks"
                let subRoot = repoRoot.appendingPathComponent(sub)
                
                let embedSrc = subRoot.appendingPathComponent("embed_weight.bin")
                let embedDest = destDir.appendingPathComponent("embed_weight.bin")
                if FileManager.default.fileExists(atPath: embedSrc.path) {
                    try? FileManager.default.removeItem(at: embedDest)
                    try FileManager.default.copyItem(at: embedSrc, to: embedDest)
                }
                
                let chunkNames = (0..<4).map { "chunk_\($0)" } + ["chunk_head"]
                for (index, chunkName) in chunkNames.enumerated() {
                    guard !Task.isCancelled else { return }
                    let phaseProgress = 0.5 + 0.5 * Double(index) / Double(chunkNames.count)
                    await MainActor.run { state = .downloading(progress: phaseProgress) }
                    
                    let compiledDest = destDir.appendingPathComponent("\(chunkName).mlmodelc")
                    let mlcSrc = subRoot.appendingPathComponent("\(chunkName).mlmodelc")
                    if FileManager.default.fileExists(atPath: mlcSrc.path) {
                        try? FileManager.default.removeItem(at: compiledDest)
                        try FileManager.default.copyItem(at: mlcSrc, to: compiledDest)
                    }
                }
            } else {
                let modelSrc = repoRoot.appendingPathComponent("model.mlmodelc")
                let modelDest = destDir.appendingPathComponent("model.mlmodelc")
                if FileManager.default.fileExists(atPath: modelSrc.path) {
                    try? FileManager.default.removeItem(at: modelDest)
                    try FileManager.default.copyItem(at: modelSrc, to: modelDest)
                }
            }

            await MainActor.run { state = .ready }
            print("[ModelDownload] All files ready for \(selectedConfig.rawValue).")

        } catch {
            if Task.isCancelled {
                await MainActor.run { state = .notDownloaded }
                return
            }
            print("[ModelDownload] Failed: \(error)")
            await MainActor.run { state = .failed(error.localizedDescription) }
        }
    }
}
