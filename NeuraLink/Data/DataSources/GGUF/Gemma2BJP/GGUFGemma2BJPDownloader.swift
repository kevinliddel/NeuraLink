//
//  GGUFGemma2BJPDownloader.swift
//  NeuraLink
//
//  Downloads the Japanese local model GGUF file from HuggingFace.
//  Model: mmnga/llm-jp-3-1.8b-instruct3-gguf
//  File:  llm-jp-3-1.8b-instruct3-Q3_K_M.gguf (~0.96 GB) — see GGUFGemma2BJPModelAccess
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation
import Hub

enum GGUFGemma2BJPDownloader {

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
        let repo = Hub.Repo(id: GGUFGemma2BJPModelAccess.repoID)
        // Fetch only the one quant we use — see GGUFLlamaDownloader for the
        // full rationale (multi-quant repos balloon to 4–8 GB without this).
        let snapshotDir = try await api.snapshot(
            from: repo, matching: [GGUFGemma2BJPModelAccess.filename]
        ) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    // MARK: - Private

    private static func verifyAndSave(snapshotDir: URL) throws {
        let direct = snapshotDir.appendingPathComponent(GGUFGemma2BJPModelAccess.filename)
        if FileManager.default.fileExists(atPath: direct.path) {
            GGUFGemma2BJPModelAccess.setModelPath(direct)
            return
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            let candidate = entry.appendingPathComponent(GGUFGemma2BJPModelAccess.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                GGUFGemma2BJPModelAccess.setModelPath(candidate)
                return
            }
        }

        throw DownloadError.fileMissing
    }
}
