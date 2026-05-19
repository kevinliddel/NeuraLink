//
//  GGUFQwen7BDownloader.swift
//  NeuraLink
//
//  Downloads the single-file Qwen-2.5-7B-Instruct GGUF from HuggingFace.
//  File: Qwen2.5-7B-Instruct-Q4_K_M.gguf (~4.68 GB)
//
//  Created by Dedicatus on 18/05/2026.
//

import Foundation
import Hub

enum GGUFQwen7BDownloader {

    enum DownloadError: LocalizedError {
        case fileMissing

        var errorDescription: String? {
            "The Qwen-2.5-7B GGUF model file was not found in the downloaded repository."
        }
    }

    static func download(
        api: HubApi,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let repo = Hub.Repo(id: GGUFQwen7BModelAccess.repoID)
        // Fetch only the one quant we use — see GGUFLlamaDownloader. This
        // matters most for the 7B repo where the f16 variant alone is
        // ~14 GB and the full repo can exceed 50 GB across quants.
        let snapshotDir = try await api.snapshot(
            from: repo, matching: [GGUFQwen7BModelAccess.filename]
        ) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    private static func verifyAndSave(snapshotDir: URL) throws {
        let direct = snapshotDir.appendingPathComponent(GGUFQwen7BModelAccess.filename)
        if FileManager.default.fileExists(atPath: direct.path) {
            GGUFQwen7BModelAccess.setModelPath(direct)
            return
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            let candidate = entry.appendingPathComponent(GGUFQwen7BModelAccess.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                GGUFQwen7BModelAccess.setModelPath(candidate)
                return
            }
        }

        throw DownloadError.fileMissing
    }
}
