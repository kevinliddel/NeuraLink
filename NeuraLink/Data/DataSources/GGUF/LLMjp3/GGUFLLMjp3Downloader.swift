//
//  GGUFLLMjp3Downloader.swift
//  NeuraLink
//
//  Downloads the Japanese local model GGUF file from HuggingFace.
//  Model: mmnga/llm-jp-3-1.8b-instruct3-gguf
//  File:  llm-jp-3-1.8b-instruct3-Q3_K_M.gguf (~0.96 GB) — see GGUFLLMjp3ModelAccess
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation
import Hub

enum GGUFLLMjp3Downloader {

    // MARK: - Error

    enum DownloadError: LocalizedError {
        case fileMissing

        var errorDescription: String? {
            "The Japanese Llama GGUF model file was not found in the downloaded repository."
        }
    }

    // MARK: - API

    static func download(
        api: HubApi,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let repo = Hub.Repo(id: GGUFLLMjp3ModelAccess.repoID)
        // Fetch only the one quant we use — see GGUFLlamaDownloader for the
        // full rationale (multi-quant repos balloon to 4–8 GB without this).
        let snapshotDir = try await api.snapshot(
            from: repo, matching: [GGUFLLMjp3ModelAccess.filename]
        ) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    // MARK: - Private

    private static func verifyAndSave(snapshotDir: URL) throws {
        let direct = snapshotDir.appendingPathComponent(GGUFLLMjp3ModelAccess.filename)
        if FileManager.default.fileExists(atPath: direct.path) {
            GGUFLLMjp3ModelAccess.setModelPath(direct)
            return
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            let candidate = entry.appendingPathComponent(GGUFLLMjp3ModelAccess.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                GGUFLLMjp3ModelAccess.setModelPath(candidate)
                return
            }
        }

        throw DownloadError.fileMissing
    }
}
