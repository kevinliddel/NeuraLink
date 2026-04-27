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

    private(set) var state: DownloadState = .notDownloaded
    private var activeTask: Task<Void, Never>?

    // HuggingFace repo hosting the chunked Qwen3-VL 2B CoreML weights.
    static let repoID = "mlboydaisuke/qwen3-vl-2b-stateful-coreml"

    // Subdirectory inside the repo that contains the model files.
    static let repoSubdir = "qwen3_vl_2b_stateful_chunks"

    // Logical chunk names (excludes extension — callers append .mlmodelc / .mlpackage).
    static let chunkNames: [String] = (0..<4).map { "chunk_\($0)" } + ["chunk_head"]

    // Estimated total download size shown in the UI (mlpackages + embed).
    static let estimatedSizeGB: Double = 2.7

    /// Where compiled .mlmodelc and embed_weight.bin live after download.
    var compiledDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuraLink/LocalModels/qwen3-vl-2b", isDirectory: true)
    }

    var isAvailable: Bool {
        switch state {
        case .bundled, .ready: return true
        default: return false
        }
    }

    private init() { refreshState() }

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
        let chunksOK = Self.chunkNames.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).mlmodelc").path)
        }
        let embedOK = FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("embed_weight.bin").path)
        return chunksOK && embedOK
    }

    // MARK: - URL resolution (called by engine loaders)

    /// Returns the .mlmodelc URL for a given chunk name, or nil if unavailable.
    func urlForChunk(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        let cached = compiledDir.appendingPathComponent("\(name).mlmodelc")
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
                return "Repository '\(LocalModelDownloadManager.repoID)' was not found on Hugging Face. Make sure the repo is public and the ID in LocalModelDownloadManager.swift is correct."
            case .chunkMissing(let name):
                return "'\(name)' not found in the repository (neither .mlpackage nor .mlmodelc). The repo structure may differ from expected."
            }
        }
    }

    private func performDownload() async {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let api = HubApi(downloadBase: appSupport)
        let repo = Hub.Repo(id: Self.repoID)
        let destDir = compiledDir

        do {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

            // Phase 1 (0 → 0.5): Hub snapshot — files live inside repoSubdir/.
            await MainActor.run { state = .downloading(progress: 0.0) }

            let sub = Self.repoSubdir
            var globs: [String] = ["\(sub)/embed_weight.bin"]
            for name in Self.chunkNames {
                globs.append("\(sub)/\(name).mlpackage/**")
                globs.append("\(sub)/\(name).mlmodelc/**")
            }

            let snapshotDir = try await api.snapshot(from: repo, matching: globs) { progress in
                Task { @MainActor in
                    guard case .downloading = self.state else { return }
                    self.state = .downloading(progress: progress.fractionCompleted * 0.5)
                }
            }

            guard !Task.isCancelled else { return }

            // Sanity check: Hub silently returns an empty dir when the repo doesn't exist.
            // embed_weight.bin presence confirms the download actually succeeded.
            let repoRoot = snapshotDir.appendingPathComponent(sub)
            let embedSrc = repoRoot.appendingPathComponent("embed_weight.bin")
            guard FileManager.default.fileExists(atPath: embedSrc.path) else {
                throw DownloadError.repositoryNotFound
            }

            // Copy embed_weight.bin
            let embedDest = destDir.appendingPathComponent("embed_weight.bin")
            if !FileManager.default.fileExists(atPath: embedDest.path) {
                try FileManager.default.copyItem(at: embedSrc, to: embedDest)
            }

            // Phase 2 (0.5 → 1.0): process chunks — repo ships .mlpackage only.
            let totalChunks = Double(Self.chunkNames.count)

            for (index, chunkName) in Self.chunkNames.enumerated() {
                guard !Task.isCancelled else { return }

                let phaseProgress = 0.5 + 0.5 * Double(index) / totalChunks
                await MainActor.run { state = .downloading(progress: phaseProgress) }

                let compiledDest = destDir.appendingPathComponent("\(chunkName).mlmodelc")
                guard !FileManager.default.fileExists(atPath: compiledDest.path) else { continue }

                // Prefer pre-compiled .mlmodelc if present (no compilation step needed)
                let mlcSrc = repoRoot.appendingPathComponent("\(chunkName).mlmodelc")
                if FileManager.default.fileExists(atPath: mlcSrc.path) {
                    try FileManager.default.copyItem(at: mlcSrc, to: compiledDest)
                    continue
                }

                // Compile the .mlpackage on-device
                let pkgSrc = repoRoot.appendingPathComponent("\(chunkName).mlpackage")
                guard FileManager.default.fileExists(atPath: pkgSrc.path) else {
                    throw DownloadError.chunkMissing(chunkName)
                }

                let compiledURL = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            continuation.resume(returning: try MLModel.compileModel(at: pkgSrc))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                try? FileManager.default.removeItem(at: compiledDest)
                try FileManager.default.moveItem(at: compiledURL, to: compiledDest)
            }

            await MainActor.run { state = .ready }
            print("[ModelDownload] All chunks ready.")

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
