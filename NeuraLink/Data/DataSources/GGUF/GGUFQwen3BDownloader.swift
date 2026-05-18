//
//  GGUFQwen3BDownloader.swift
//  NeuraLink
//
//  Downloads the single-file Qwen-2.5-3B-Instruct GGUF from HuggingFace.
//  File: Qwen2.5-3B-Instruct-Q4_K_M.gguf (~1.93 GB)
//
//  Created by Dedicatus on 18/05/2026.
//

import Foundation
import Hub

enum GGUFQwen3BDownloader {

    enum DownloadError: LocalizedError {
        case fileMissing

        var errorDescription: String? {
            "The Qwen-2.5-3B GGUF model file was not found in the downloaded repository."
        }
    }

    static func download(
        api: HubApi,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let repo = Hub.Repo(id: GGUFQwen3BModelAccess.repoID)
        let snapshotDir = try await api.snapshot(from: repo) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    private static func verifyAndSave(snapshotDir: URL) throws {
        let direct = snapshotDir.appendingPathComponent(GGUFQwen3BModelAccess.filename)
        if FileManager.default.fileExists(atPath: direct.path) {
            GGUFQwen3BModelAccess.setModelPath(direct)
            return
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            let candidate = entry.appendingPathComponent(GGUFQwen3BModelAccess.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                GGUFQwen3BModelAccess.setModelPath(candidate)
                return
            }
        }

        throw DownloadError.fileMissing
    }
}
