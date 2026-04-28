//
//  LlamaModelDownloader.swift
//  NeuraLink
//
//  Handles the Hub download and on-disk verification for
//  smpanaro/Llama-3.2-1B-Instruct-CoreML.
//
//  Repo layout (all .mlmodelc at snapshot root):
//    Llama-3.2-1B-Instruct_chunk1.mlmodelc … chunk6.mlmodelc  (6 body chunks)
//    cache-processor.mlmodelc
//    logit-processor.mlmodelc
//
//  Created by Dedicatus on 28/04/2026.
//

import Foundation
import Hub

enum LlamaModelDownloader {

    // MARK: - Error

    enum DownloadError: LocalizedError {
        case chunkMissing(String)

        var errorDescription: String? {
            switch self {
            case .chunkMissing(let name):
                return "'\(name)' not found in the downloaded Llama repository."
            }
        }
    }

    // MARK: - API

    /// Downloads the Llama model snapshot from Hub, verifies the chunk layout,
    /// and persists the resolved snapshot directory via `LlamaModelAccess`.
    ///
    /// - Parameters:
    ///   - api: Pre-configured `HubApi` instance (download base already set).
    ///   - progressHandler: Receives fractional progress in 0…0.95 on any thread.
    static func download(
        api: HubApi,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let repo = Hub.Repo(id: LlamaModelAccess.repoID)
        let snapshotDir = try await api.snapshot(from: repo) { progress in
            progressHandler(progress.fractionCompleted * 0.95)
        }
        try verifyAndSave(snapshotDir: snapshotDir)
    }

    // MARK: - Private

    private static func verifyAndSave(snapshotDir: URL) throws {
        // Fast path: all chunks are at the snapshot root.
        if LlamaModelAccess.isComplete(at: snapshotDir) {
            LlamaModelAccess.setSnapshotDir(snapshotDir)
            return
        }

        // Slow path: Hub may nest chunks one directory level deep.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snapshotDir, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            throw DownloadError.chunkMissing("Llama-3.2-1B-Instruct_chunk1.mlmodelc")
        }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // Skip .mlmodelc bundles themselves — only traverse plain directories.
            guard isDir, entry.pathExtension != "mlmodelc" else { continue }
            if LlamaModelAccess.isComplete(at: entry) {
                LlamaModelAccess.setSnapshotDir(entry)
                return
            }
        }

        throw DownloadError.chunkMissing("Llama-3.2-1B-Instruct_chunk1.mlmodelc")
    }
}
