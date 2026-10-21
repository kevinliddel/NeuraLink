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
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        // Direct fetch of the one file, with real byte progress and resume
        // (GGUFDirectDownloader); `api` is kept for the call sites' signature.
        _ = api
        let file = try await GGUFDirectDownloader.download(
            repoID: GGUFModelAccess.repoID, filename: GGUFModelAccess.filename, hubSlug: GGUFModelAccess.hubSlug,
            progress: { progressHandler($0) })
        GGUFModelAccess.setModelPath(file)
    }

    // MARK: - Private
}
