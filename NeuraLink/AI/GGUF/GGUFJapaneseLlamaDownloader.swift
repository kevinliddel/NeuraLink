//
//  GGUFJapaneseLlamaDownloader.swift
//  NeuraLink
//
//  Downloads the Japanese-oriented Llama-3.2-1B GGUF model from HuggingFace.
//  Model: grapevine-AI/Llama-3.2-1B-Instruct-GGUF
//  File:  Llama-3.2-1B-Instruct-Q4_K_M.gguf (~808 MB)
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation
import Hub

enum GGUFJapaneseLlamaDownloader {

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
        let repo = Hub.Repo(id: GGUFJapaneseLlamaModelAccess.repoID)
        let snapshotDir = try await api.snapshot(from: repo) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    // MARK: - Private

    private static func verifyAndSave(snapshotDir: URL) throws {
        let direct = snapshotDir.appendingPathComponent(GGUFJapaneseLlamaModelAccess.filename)
        if FileManager.default.fileExists(atPath: direct.path) {
            GGUFJapaneseLlamaModelAccess.setModelPath(direct)
            return
        }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for entry in entries {
            let candidate = entry.appendingPathComponent(GGUFJapaneseLlamaModelAccess.filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                GGUFJapaneseLlamaModelAccess.setModelPath(candidate)
                return
            }
        }

        throw DownloadError.fileMissing
    }
}
