//
//  GGUFLlamaDownloader.swift
//  NeuraLink
//
//  Downloads the single-file GGUF model from bartowski/Llama-3.2-1B-Instruct-GGUF.
//  Replaces the multi-chunk CoreML snapshot download in LlamaModelDownloader.
//
//  Download target (from `GGUFModelAccess.filename`):
//    Llama-3.2-1B-Instruct-Q8_0.gguf  (~1.32 GB)
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation
import Hub

enum GGUFLlamaDownloader {

    // MARK: - Error

    enum DownloadError: LocalizedError {
        case fileMissing

        var errorDescription: String? {
            "The GGUF model file was not found in the downloaded repository."
        }
    }

    // MARK: - API

    /// Downloads the GGUF model snapshot from HuggingFace Hub, verifies the file,
    /// and persists the resolved path via `GGUFModelAccess`.
    ///
    /// - Parameters:
    ///   - api:             Pre-configured `HubApi` instance.
    ///   - progressHandler: Receives fractional progress in 0…0.95 on any thread.
    static func download(
        api: HubApi,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let repo = Hub.Repo(id: GGUFModelAccess.repoID)
        // CRITICAL: pass `matching:` so HubApi fetches ONLY the one quant we
        // use (Q8_0). Without this, snapshot pulls every file in the repo
        // — for bartowski's GGUF repos that's 18+ quantization variants
        // totalling 10+ GB per "download" of a 1.32 GB model.
        let snapshotDir = try await api.snapshot(
            from: repo, matching: [GGUFModelAccess.filename]
        ) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    // MARK: - Private

    private static func verifyAndSave(snapshotDir: URL) throws {
        let direct = snapshotDir.appendingPathComponent(GGUFModelAccess.filename)
        if FileManager.default.fileExists(atPath: direct.path) {
            GGUFModelAccess.setModelPath(direct)
            return
        }

        // Hub may place the file one level deeper — scan one level.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            let candidate = entry.appendingPathComponent(GGUFModelAccess.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                GGUFModelAccess.setModelPath(candidate)
                return
            }
        }

        throw DownloadError.fileMissing
    }
}
