//
//  GGUFQwenDownloader.swift
//  NeuraLink
//
//  Downloads the single-file Qwen GGUF model from HuggingFace.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation
import Hub

enum GGUFQwenDownloader {

    enum DownloadError: LocalizedError {
        case fileMissing

        var errorDescription: String? {
            "The GGUF model file was not found in the downloaded repository."
        }
    }

    static func download(
        api: HubApi,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let repo = Hub.Repo(id: GGUFQwenModelAccess.repoID)
        // Fetch only the one quant we use — see GGUFLlamaDownloader.
        let snapshotDir = try await api.snapshot(
            from: repo, matching: [GGUFQwenModelAccess.filename]
        ) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    private static func verifyAndSave(snapshotDir: URL) throws {
        let direct = snapshotDir.appendingPathComponent(GGUFQwenModelAccess.filename)
        if FileManager.default.fileExists(atPath: direct.path) {
            GGUFQwenModelAccess.setModelPath(direct)
            return
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            let candidate = entry.appendingPathComponent(GGUFQwenModelAccess.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                GGUFQwenModelAccess.setModelPath(candidate)
                return
            }
        }

        throw DownloadError.fileMissing
    }
}
