//
//  QwenModelDownloader.swift
//  NeuraLink
//
//  Handles the Hub download and on-disk verification for
//  mlboydaisuke/qwen3-vl-2b-stateful-coreml.
//
//  Repo layout (inside qwen3_vl_2b_stateful_chunks/):
//    chunk_0.mlpackage … chunk_3.mlpackage   (4 body chunks)
//    chunk_head.mlpackage
//    embed_weight.bin                         (622 MB token embed table)
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation
import Hub

enum QwenModelDownloader {

    // MARK: - Error

    enum DownloadError: LocalizedError {
        case chunkMissing(String)

        var errorDescription: String? {
            switch self {
            case .chunkMissing(let name):
                return "'\(name)' not found in the downloaded Qwen repository."
            }
        }
    }

    // MARK: - API

    /// Downloads the Qwen model snapshot from Hub, verifies the chunk layout,
    /// and persists the resolved chunk directory via `QwenModelAccess`.
    ///
    /// - Parameters:
    ///   - api: Pre-configured `HubApi` instance (download base already set).
    ///   - progressHandler: Receives fractional progress in 0…0.95 on any thread.
    static func download(
        api: HubApi,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let repo = Hub.Repo(id: QwenModelAccess.repoID)
        let snapshotDir = try await api.snapshot(from: repo) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    // MARK: - Private

    private static func verifyAndSave(snapshotDir: URL) throws {
        // The chunks live in a named subdirectory; fall back to snapshot root.
        let sub = snapshotDir.appendingPathComponent("qwen3_vl_2b_stateful_chunks")

        if QwenModelAccess.isComplete(at: sub) {
            QwenModelAccess.setChunkDir(sub)
        } else if QwenModelAccess.isComplete(at: snapshotDir) {
            QwenModelAccess.setChunkDir(snapshotDir)
        } else {
            throw DownloadError.chunkMissing("chunk_0.mlpackage")
        }
    }
}
